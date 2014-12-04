var app = angular.module('Workbench', ['Arvados']);
app.controller('UploadToCollection', UploadToCollection);
app.directive('arvUuid', arvUuid);

function arvUuid() {
    // Copy the given uuid into the current $scope.
    return {
        restrict: 'A',
        link: function(scope, element, attributes) {
            scope.uuid = attributes.arvUuid;
        }
    };
}

UploadToCollection.$inject = ['$scope', '$filter', '$q', '$timeout',
                              'ArvadosClient', 'arvadosApiToken'];
function UploadToCollection($scope, $filter, $q, $timeout,
                            ArvadosClient, arvadosApiToken) {
    $.extend($scope, {
        uploadQueue: [],
        uploader: new QueueUploader(),
        addFilesToQueue: function(files) {
            // Angular binding doesn't work its usual magic for file
            // inputs, so we need to $scope.$apply() this update.
            $scope.$apply(function(){
                var i;
                var insertAt;
                for (insertAt=0; (insertAt<$scope.uploadQueue.length &&
                                  $scope.uploadQueue[insertAt].state != 'Done');
                     insertAt++);
                for (i=0; i<files.length; i++) {
                    $scope.uploadQueue.splice(insertAt+i, 0,
                        new FileUploader(files[i]));
                }
            });
        },
        go: function() {
            $scope.uploader.go();
        },
        stop: function() {
            $scope.uploader.stop();
        },
        removeFileFromQueue: function(index) {
            var wasRunning = $scope.uploader.running;
            $scope.uploadQueue[index].stop();
            $scope.uploadQueue.splice(index, 1);
            if (wasRunning)
                $scope.go();
        },
        countInStates: function(want_states) {
            var found = 0;
            $.each($scope.uploadQueue, function() {
                if (want_states.indexOf(this.state) >= 0) {
                    ++found;
                }
            });
            return found;
        }
    });
    ////////////////////////////////

    var keepProxy;

    function SliceReader(_slice) {
        var that = this;
        $.extend(this, {
            go: go
        });
        ////////////////////////////////
        var _deferred;
        var _reader;
        function go() {
            // Return a promise, which will be resolved with the
            // requested slice data.
            _deferred = $.Deferred();
            _reader = new FileReader();
            _reader.onload = resolve;
            _reader.onerror = _deferred.reject;
            _reader.onprogress = _deferred.notify;
            _reader.readAsArrayBuffer(_slice.blob);
            return _deferred.promise();
        }
        function resolve() {
            if (that._reader.result.length != that._slice.size) {
                // Sometimes we get an onload event even if the read
                // did not return the desired number of bytes. We
                // treat that as a fail.
                _deferred.reject(
                    null, "Read error",
                    "Short read: wanted " + _slice.size +
                        ", received " + _reader.result.length);
                return;
            }
            return _deferred.resolve(_reader.result);
        }
    }

    function SliceUploader(_label, _data, _dataSize) {
        $.extend(this, {
            go: go,
            stop: stop
        });
        ////////////////////////////////
        var that = this;
        var _deferred;
        var _failCount = 0;
        var _failMax = 3;
        var _jqxhr;
        function go() {
            // Send data to the Keep proxy. Retry a few times on
            // fail. Return a promise that will get resolved with
            // resolve(locator) when the block is accepted by the
            // proxy.
            _deferred = $.Deferred();
            goSend();
            return _deferred.promise();
        }
        function stop() {
            _failMax = 0;
            _jqxhr.abort();
            _deferred.reject({
                textStatus: 'stopped',
                err: 'interrupted at slice '+_label
            });
        }
        function goSend() {
            _jqxhr = $.ajax({
                url: proxyUriBase(),
                type: 'POST',
                crossDomain: true,
                headers: {
                    'Authorization': 'OAuth2 '+arvadosApiToken,
                    'Content-Type': 'application/octet-stream',
                    'X-Keep-Desired-Replicas': '2'
                },
                xhr: function() {
                    // Make an xhr that reports upload progress
                    var xhr = $.ajaxSettings.xhr();
                    if (xhr.upload) {
                        xhr.upload.onprogress = onSendProgress;
                    }
                    return xhr;
                },
                processData: false,
                data: _data
            });
            _jqxhr.then(onSendResolve, onSendReject);
        }
        function onSendProgress(xhrProgressEvent) {
            _deferred.notify(xhrProgressEvent.loaded, _dataSize);
        }
        function onSendResolve(data, textStatus, jqxhr) {
            _deferred.resolve(data, _dataSize);
        }
        function onSendReject(xhr, textStatus, err) {
            if (++_failCount < _failMax) {
                // TODO: nice to tell the user that retry is happening.
                console.log('slice ' + _label + ': ' +
                            textStatus + ', retry ' + _failCount);
                goSend();
            } else {
                _deferred.reject(
                    {xhr: xhr, textStatus: textStatus, err: err});
            }
        }
        function proxyUriBase() {
            return ((keepProxy.service_ssl_flag ? 'https' : 'http') +
                    '://' + keepProxy.service_host + ':' +
                    keepProxy.service_port + '/');
        }
    }

    function FileUploader(file) {
        $.extend(this, {
            committed: false,
            file: file,
            locators: [],
            progress: 0.0,
            state: 'Queued',    // Queued, Uploading, Paused, Done
            statistics: null,
            go: go,
            stop: stop          // User wants to stop.
        });
        ////////////////////////////////
        var that = this;
        var _currentUploader;
        var _currentSlice;
        var _deferred;
        var _maxBlobSize = Math.pow(2,26);
        var _bytesDone = 0;
        var _queueTime = Date.now();
        var _startTime;
        var _startByte;
        var _finishTime;
        var _readPos = 0;       // number of bytes confirmed uploaded
        function go() {
            if (_deferred)
                _deferred.reject({textStatus: 'restarted'});
            _deferred = $q.defer();
            that.state = 'Uploading';
            _startTime = Date.now();
            _startByte = _readPos;
            setProgress();
            goSlice();
            return _deferred.promise;
        }
        function stop() {
            if (_deferred) {
                that.state = 'Paused';
                _deferred.reject({textStatus: 'stopped', err: 'interrupted'});
            }
            if (_currentUploader) {
                _currentUploader.stop();
                _currentUploader = null;
            }
        }
        function goSlice() {
            // Ensure this._deferred gets resolved or rejected --
            // either right here, or when a new promise arranged right
            // here is fulfilled.
            _currentSlice = nextSlice();
            if (!_currentSlice) {
                that.state = 'Done';
                setProgress(_readPos);
                _currentUploader = null;
                _deferred.resolve([that]);
                return;
            }
            _currentUploader = new SliceUploader(
                _readPos.toString(),
                _currentSlice.blob,
                _currentSlice.size);
            _currentUploader.go().then(
                onUploaderResolve,
                onUploaderReject,
                onUploaderProgress);
        }
        function onUploaderResolve(locator, dataSize) {
            if (!locator || _currentSlice.size != dataSize) {
                console.log("onUploaderResolve but locator=" + locator +
                            " and " + _currentSlice.size + " != " + dataSize);
                return onUploaderReject({
                    textStatus: "error",
                    err: "Bad response from slice upload"
                });
            }
            that.locators.push(locator);
            _readPos += dataSize;
            _currentUploader = null;
            goSlice();
        }
        function onUploaderReject(reason) {
            that.state = 'Paused';
            setProgress(_readPos);
            _currentUploader = null;
            _deferred.reject(reason);
        }
        function onUploaderProgress(sliceDone, sliceSize) {
            setProgress(_readPos + sliceDone);
        }
        function nextSlice() {
            var size = Math.min(
                _maxBlobSize,
                that.file.size - _readPos);
            setProgress(_readPos);
            if (size == 0) {
                return false;
            }
            var blob = that.file.slice(
                _readPos, _readPos+size,
                'application/octet-stream; charset=x-user-defined');
            return {blob: blob, size: size};
        }
        function setProgress(bytesDone) {
            var kBps;
            that.progress = Math.min(100, 100 * bytesDone / that.file.size)
            if (bytesDone > _startByte) {
                kBps = (bytesDone - _startByte) /
                    (Date.now() - _startTime);
                that.statistics = (
                    '' + $filter('number')(bytesDone/1024, '0') + ' KiB ' +
                        'at ~' + $filter('number')(kBps, '0') + ' KiB/s')
                if (that.state == 'Paused') {
                    that.statistics += ', paused';
                } else if (that.state == 'Uploading') {
                    that.statistics += ', ETA ' +
                        $filter('date')(
                            new Date(
                                Date.now() + (that.file.size - bytesDone) / kBps),
                            'shortTime')
                } else {
                    that.statistics += ', finished ' +
                        $filter('date')(Date.now(), 'shortTime');
                    _finishTime = Date.now();
                }
            } else {
                that.statistics = that.state;
            }
            _deferred.notify();
        }
    }

    function QueueUploader() {
        $.extend(this, {
            state: 'Idle',
            stateReason: null,
            statusSuccess: null,
            go: go,
            stop: stop
        });
        ////////////////////////////////
        var that = this;
        var _deferred;
        function go() {
            if (that.state == 'Running') return _deferred.promise;
            _deferred = $.Deferred();
            that.state = 'Running';
            ArvadosClient.apiPromise(
                'keep_services', 'list',
                {filters: [['service_type','=','proxy']]}).
                then(doQueueWithProxy);
            onQueueProgress();
            return _deferred.promise();
        }
        function stop() {
            for (var i=0; i<$scope.uploadQueue.length; i++)
                $scope.uploadQueue[i].stop();
        }
        function doQueueWithProxy(data) {
            keepProxy = data.items[0];
            if (!keepProxy) {
                that.state = 'Failed';
                that.stateReason =
                    'There seems to be no Keep proxy service available.';
                _deferred.reject(null, 'error', that.stateReason);
                return;
            }
            return doQueueWork();
        }
        function doQueueWork() {
            var i;
            that.state = 'Running';
            that.stateReason = null;
            // Push the done things to the bottom of the queue.
            for (i=0; (i<$scope.uploadQueue.length &&
                       $scope.uploadQueue[i].state == 'Done'); i++);
            if (i>0)
                $scope.uploadQueue.push.apply($scope.uploadQueue, $scope.uploadQueue.splice(0, i));
            // If anything is not-done, do it.
            if ($scope.uploadQueue.length > 0 &&
                $scope.uploadQueue[0].state != 'Done') {
                return $scope.uploadQueue[0].go().
                    then(appendToCollection, null, onQueueProgress).
                    then(doQueueWork, onQueueReject);
            }
            // If everything is done, resolve the promise and clean up.
            return onQueueResolve();
        }
        function onQueueReject(reason) {
            that.state = 'Failed';
            that.stateReason = (
                (reason.textStatus || 'Error') +
                    (reason.xhr && reason.xhr.options
                     ? (' (from ' + reason.xhr.options.url + ')')
                     : '') +
                    ': ' +
                    (reason.err || ''));
            if (reason.xhr && reason.xhr.responseText)
                that.stateReason += ' -- ' + reason.xhr.responseText;
            _deferred.reject(reason);
            onQueueProgress();
        }
        function onQueueResolve() {
            that.state = 'Idle';
            that.stateReason = 'Done!';
            _deferred.resolve();
            onQueueProgress();
        }
        function onQueueProgress() {
            // Ensure updates happen after FileUpload promise callbacks.
            $timeout(function(){$scope.$apply();});
        }
        function appendToCollection(uploads) {
            var deferred = $q.defer();
            return ArvadosClient.apiPromise(
                'collections', 'get',
                { uuid: $scope.uuid }).
                then(function(collection) {
                    var manifestText = '';
                    var upload, i;
                    for (i=0; i<uploads.length; i++) {
                        upload = uploads[i];
                        filename = ArvadosClient.uniqueNameForManifest(
                            collection.manifest_text,
                            '.', upload.file.name);
                        collection.manifest_text += '. ' +
                            upload.locators.join(' ') +
                            ' 0:' + upload.file.size.toString() + ':' +
                            filename +
                            '\n';
                    }
                    return ArvadosClient.apiPromise(
                        'collections', 'update',
                        { uuid: $scope.uuid,
                          collection:
                          { manifest_text:
                            collection.manifest_text }
                        }).
                        then(deferred.resolve);
                }, onQueueReject).then(function() {
                    var i;
                    for(i=0; i<uploads.length; i++) {
                        uploads[i].committed = true;
                    }
                });
            return deferred.promise.then(doQueueWork);
        }
    }
}
