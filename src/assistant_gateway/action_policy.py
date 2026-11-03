"""Offline review of model proposals. This module cannot apply or transmit anything.

This intentionally exposes a smaller surface than the manual configuration UI.
FPGA capability/epoch/freshness checks and explicit user confirmation belong to
the future executor and are NOT replaced by a successful review here.
"""
from __future__ import annotations

from dataclasses import dataclass
from hashlib import sha256
import json
from pathlib import Path

# The schema travels with the package. Look next to this file first (assistant_gateway/protocol),
# then fall back to the historical donor layout (../protocol) so both trees keep working.
_HERE = Path(__file__).resolve().parent
SCHEMA = _HERE / "protocol" / "schema.json"
if not SCHEMA.exists():
    SCHEMA = _HERE.parents[0] / "protocol" / "schema.json"
ALLOW = frozenset({"next_preset", "next_group", "next_octave",
                   "partial_target", "chorus_wet_max"})
MAX_REQUEST_BYTES = 4096


class ProposalRejected(ValueError):
    pass


def _pairs(pairs):
    result = {}
    for name, value in pairs:
        if name in result:
            raise ProposalRejected("DUPLICATE_KEY")
        result[name] = value
    return result


def _nonfinite(_value):
    raise ProposalRejected("NONFINITE_NUMBER")


@dataclass(frozen=True)
class PatchPreview:
    changes: tuple[tuple[str, int], ...]
    schema_sha256: str
    proposal_sha256: str
    state: str = "PREVIEW_ONLY"
    requires_confirmation: bool = True


def review(raw: bytes, *, schema_path: Path = SCHEMA) -> PatchPreview:
    """Strictly parse and review a small patch; never clamp or partially accept it."""
    if not isinstance(raw, bytes):
        raise ProposalRejected("BYTES_REQUIRED")
    if not raw or len(raw) > MAX_REQUEST_BYTES:
        raise ProposalRejected("SIZE")
    try:
        obj = json.loads(raw.decode("utf-8"), object_pairs_hook=_pairs,
                         parse_constant=_nonfinite)
    except ProposalRejected:
        raise
    except (ValueError, UnicodeError, RecursionError) as exc:
        raise ProposalRejected("INVALID_JSON") from exc
    if type(obj) is not dict or set(obj) != {"version", "kind", "changes"}:
        raise ProposalRejected("ENVELOPE")
    if type(obj["version"]) is not int or obj["version"] != 1:
        raise ProposalRejected("VERSION")
    if obj["kind"] != "config_patch":
        raise ProposalRejected("KIND")
    changes = obj["changes"]
    if type(changes) is not dict or not 1 <= len(changes) <= len(ALLOW):
        raise ProposalRejected("CHANGES")
    schema_bytes = schema_path.read_bytes()
    fields = {f["name"]: f for f in json.loads(schema_bytes)["config"]["fields"]}
    for name, value in changes.items():
        if name not in ALLOW or name not in fields:
            raise ProposalRejected("FIELD_NOT_ALLOWED")
        field = fields[name]
        if field.get("readonly", True):
            raise ProposalRejected("READONLY")
        if type(value) is not int:  # bool is an int subclass; it is not a wire integer.
            raise ProposalRejected("INTEGER_REQUIRED")
        if not field["min"] <= value <= field["max"]:
            raise ProposalRejected("RANGE")
    canonical = json.dumps(obj, sort_keys=True, separators=(",", ":"),
                           ensure_ascii=True).encode("ascii")
    return PatchPreview(tuple(sorted(changes.items())), sha256(schema_bytes).hexdigest(),
                        sha256(canonical).hexdigest())
