"""Adversarial contract tests; no network, API credentials, COM or hardware."""
import json
import unittest
from unittest.mock import Mock

from action_policy import ALLOW, SCHEMA, ProposalRejected, review


def patch(changes=None, **extras):
    return json.dumps({"version": 1, "kind": "config_patch",
                       "changes": {"next_preset": 1} if changes is None else changes,
                       **extras}).encode()


class ActionPolicyTests(unittest.TestCase):
    def test_valid_result_is_only_a_preview(self):
        result = review(patch())
        self.assertEqual(result.changes, (("next_preset", 1),))
        self.assertEqual(result.state, "PREVIEW_ONLY")
        self.assertTrue(result.requires_confirmation)

    def test_all_allowed_fields_at_both_boundaries(self):
        fields = json.loads(SCHEMA.read_text(encoding="utf-8"))["config"]["fields"]
        for f in fields:
            if f["name"] in ALLOW:
                for boundary in [f["min"], f["max"]]:
                    with self.subTest(field=f["name"], value=boundary):
                        self.assertEqual(len(review(patch({f["name"]: boundary})).changes), 1)

    def test_whole_patch_rejected_when_one_field_is_bad(self):
        with self.assertRaisesRegex(ProposalRejected, "FIELD_NOT_ALLOWED"):
            review(patch({"next_preset": 1, "dac_limit": 32767}))

    def test_manual_only_and_output_fields_are_forbidden(self):
        for name in ["pa_enable_delay", "user_attenuation", "on_threshold_zone0",
                     "note_zone0", "bend_range_semitones", "PA_EN", "raw_uart"]:
            with self.subTest(name=name), self.assertRaises(ProposalRejected):
                review(patch({name: 1}))

    def test_no_implicit_integer_conversion(self):
        for value in [True, False, 1.0, "1", None, [], {}]:
            with self.subTest(value=value), self.assertRaises(ProposalRejected):
                review(patch({"next_preset": value}))

    def test_ranges_are_rejected_without_clamping(self):
        for changes in [{"next_preset": -1}, {"next_preset": 2},
                        {"partial_target": 1}, {"partial_target": 33},
                        {"chorus_wet_max": 65}]:
            with self.subTest(changes=changes), self.assertRaisesRegex(ProposalRejected, "RANGE"):
                review(patch(changes))

    def test_duplicate_keys_rejected_at_every_level(self):
        for raw in [b'{"version":1,"version":1,"kind":"config_patch","changes":{"next_preset":1}}',
                    b'{"version":1,"kind":"config_patch","changes":{"next_preset":0,"next_preset":1}}']:
            with self.assertRaisesRegex(ProposalRejected, "DUPLICATE_KEY"):
                review(raw)

    def test_model_cannot_claim_confirmation_or_application(self):
        for extras in [{"confirmed": True}, {"requires_confirmation": False},
                       {"state": "APPLIED"}, {"shell": "anything"}]:
            with self.subTest(extras=extras), self.assertRaisesRegex(ProposalRejected, "ENVELOPE"):
                review(patch(**extras))

    def test_unknown_kind_and_versions_are_rejected(self):
        for key, value in [("kind", "GUIDE_START"), ("version", 2), ("version", True)]:
            with self.subTest(key=key, value=value), self.assertRaises(ProposalRejected):
                review(patch(**{key: value}))

    def test_non_json_nonfinite_and_bad_encoding_are_rejected(self):
        for raw in [b'```json {} ```', b'[]', b'null', b'{}', b'\xff',
                    b'{"version":1,"kind":"config_patch","changes":{"next_preset":NaN}}']:
            with self.subTest(raw=raw), self.assertRaises(ProposalRejected):
                review(raw)

    def test_size_and_empty_changes_are_rejected(self):
        for raw in [b'', b' ' * 4097, patch({})]:
            with self.assertRaises(ProposalRejected):
                review(raw)

    def test_schema_change_to_readonly_fails_closed(self):
        data = json.loads(SCHEMA.read_text(encoding="utf-8"))
        next(f for f in data["config"]["fields"] if f["name"] == "next_preset")["readonly"] = True
        path = Mock()
        path.read_bytes.return_value = json.dumps(data).encode()
        with self.assertRaisesRegex(ProposalRejected, "READONLY"):
            review(patch(), schema_path=path)

    def test_key_order_does_not_change_proposal_identity(self):
        a = review(patch({"next_preset": 1, "next_group": 0}))
        b = review(patch({"next_group": 0, "next_preset": 1}))
        self.assertEqual(a.proposal_sha256, b.proposal_sha256)
        self.assertEqual(len(a.schema_sha256), 64)


if __name__ == "__main__":
    unittest.main()
