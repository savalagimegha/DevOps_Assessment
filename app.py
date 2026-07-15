"""
Production-ready sample Flask application.

Endpoints:
    GET /            -> basic service info
    GET /health       -> liveness/readiness probe target
    GET /version       -> returns the deployed application version
"""

import os
import socket
from datetime import datetime, timezone

from flask import Flask, jsonify

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "v0.0.0-dev")
APP_NAME = os.environ.get("APP_NAME", "devops-assessment-app")


@app.route("/", methods=["GET"])
def index():
    return jsonify(
        {
            "service": APP_NAME,
            "message": "Service is running",
            "hostname": socket.gethostname(),
            "timestamp": datetime.now(timezone.utc).isoformat(),
        }
    )


@app.route("/health", methods=["GET"])
def health():
    """Used by Kubernetes liveness/readiness probes and smoke tests."""
    return jsonify({"status": "healthy"}), 200


@app.route("/version", methods=["GET"])
def version():
    return jsonify({"version": APP_VERSION}), 200


if __name__ == "__main__":
    # Only used for local development. In production, gunicorn serves the app.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 5000)))
