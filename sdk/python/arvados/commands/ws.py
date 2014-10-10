#!/usr/bin/env python

import sys
import logging
import argparse
import arvados
import json
from arvados.events import subscribe

def main(arguments=None):
    logger = logging.getLogger('arvados.arv-ws')

    parser = argparse.ArgumentParser()
    parser.add_argument('-u', '--uuid', type=str, default="")
    parser.add_argument('-f', '--filters', type=str, default="")
    parser.add_argument('-p', '--pipeline', type=str, default="", help="Print log output from a pipeline and its jobs")
    parser.add_argument('-j', '--job', type=str, default="", help="Print log output from a job")
    args = parser.parse_args(arguments)

    filters = []
    if args.uuid:
        filters += [ ['object_uuid', '=', args.uuid] ]

    if args.filters:
        filters += json.loads(args.filters)

    if args.pipeline:
        filters += [ ['object_uuid', '=', args.pipeline] ]

    if args.job:
        filters += [ ['object_uuid', '=', args.job] ]

    api = arvados.api('v1', cache=False)

    def on_message(ev):
        print json.dumps(ev)

    ws = None
    try:
        ws = subscribe(api, filters, lambda ev: on_message(ev))
        ws.run_forever()
    except KeyboardInterrupt:
        pass
    except Exception:
        logger.exception('')
    finally:
        if ws:
            ws.close_connection()
