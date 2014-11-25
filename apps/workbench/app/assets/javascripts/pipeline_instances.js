function run_pipeline_button_state() {
    var a = $('a.editable.required.editable-empty,input.form-control.required[value=""]');
    if (a.length > 0) {
        $(".run-pipeline-button").addClass("disabled");
    }
    else {
        $(".run-pipeline-button").removeClass("disabled");
    }
}

$(document).on('editable:success', function(event, tag, response, newValue) {
    var $tag = $(tag);
    if ($('.run-pipeline-button').length == 0)
        return;
    if ($tag.hasClass("required")) {
        if (newValue && newValue.trim() != "") {
            $tag.removeClass("editable-empty");
            $tag.parent().css("background-color", "");
            $tag.parent().prev().css("background-color", "");
        }
        else {
            $tag.addClass("editable-empty");
            $tag.parent().css("background-color", "#ffdddd");
            $tag.parent().prev().css("background-color", "#ffdddd");
        }
    }
    if ($tag.attr('data-name')) {
        // Update other inputs representing the same piece of data
        $('.editable[data-name="' + $tag.attr('data-name') + '"]').
            editable('setValue', newValue);
    }
    run_pipeline_button_state();
});

$(document).on('ready ajax:complete', function() {
    $('a.editable.required').each(function() {
        var $tag = $(this);
        if ($tag.hasClass("editable-empty")) {
            $tag.parent().css("background-color", "#ffdddd");
            $tag.parent().prev().css("background-color", "#ffdddd");
        }
        else {
            $tag.parent().css("background-color", "");
            $tag.parent().prev().css("background-color", "");
        }
    });
    run_pipeline_button_state();
});

$(document).on('arv-log-event', '.arv-refresh-on-state-change', function(event, eventData) {
    if (this != event.target) {
        // Not interested in events sent to child nodes.
        return;
    }
    if (eventData.event_type == "update" &&
        eventData.properties.old_attributes.state != eventData.properties.new_attributes.state)
    {
        $(event.target).trigger('arv:pane:reload');
    }
});

$(document).on('arv-log-event', '.arv-log-event-subscribe-to-pipeline-job-uuids', function(event, eventData){
    if (this != event.target) {
        // Not interested in events sent to child nodes.
        return;
    }
    if (!((eventData.object_kind == 'arvados#pipelineInstance') &&
          (eventData.event_type == "create" ||
           eventData.event_type == "update") &&
         eventData.properties &&
         eventData.properties.new_attributes &&
         eventData.properties.new_attributes.components)) {
        return;
    }
    var objs = "";
    var components = eventData.properties.new_attributes.components;
    for (a in components) {
        if (components[a].job && components[a].job.uuid) {
            objs += " " + components[a].job.uuid;
        }
    }
    $(event.target).attr("data-object-uuids", eventData.object_uuid + objs);
});

$(document).on('ready ajax:success', function() {
    $('.arv-log-refresh-control').each(function() {
        var uuids = $(this).attr('data-object-uuids');
        var $pane = $(this).closest('[data-pane-content-url]');
        $pane.attr('data-object-uuids', uuids);
    });
});

$(document).on('arv-log-event', '.arv-log-event-handler-append-logs', function(event, eventData){
    if (this != event.target) {
        // Not interested in events sent to child nodes.
        return;
    }
    var wasatbottom = ($(this).scrollTop() + $(this).height() >= this.scrollHeight);

    if (eventData.event_type == "stderr" || eventData.event_type == "stdout") {
        if( eventData.prepend ) {
            $(this).prepend(eventData.properties.text);
        } else {
            $(this).append(eventData.properties.text);
        }
    }

    if (wasatbottom) {
        this.scrollTop = this.scrollHeight;
    }
});

var showhide_compare = function() {
    var form = $('form#compare')[0];
    $('input[type=hidden][name="uuids[]"]', form).remove();
    $('input[type=submit]', form).prop('disabled',true).show();
    var checked_inputs = $('[data-object-uuid*=-d1hrv-] input[name="uuids[]"]:checked');
    if (checked_inputs.length >= 2 && checked_inputs.length <= 3) {
        checked_inputs.each(function(){
            if(this.checked) {
                $('input[type=submit]', form).prop('disabled',false).show();
                $(form).append($('<input type="hidden" name="uuids[]"/>').val(this.value));
            }
        });
    }
};
$(document).on('change', '[data-object-uuid*=-d1hrv-] input[name="uuids[]"]', function(e) {
    if(e.target == this) {
        showhide_compare();
    }
});
$(document).on('ready ajax:success', showhide_compare);
