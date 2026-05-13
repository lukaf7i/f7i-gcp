"""vertex-completion-printer — debug target for the EventBridge rule.

Logs the full EventBridge event so we can verify end-to-end that GCP
Vertex CustomJob completions reach AWS through the bridge function.
"""

import json
import logging

logging.getLogger().setLevel(logging.INFO)
log = logging.getLogger(__name__)


def handler(event, _context):
    log.info("EventBridge event: %s", json.dumps(event, default=str))
    return {"status": "logged"}
