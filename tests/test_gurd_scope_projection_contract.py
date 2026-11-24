"""Small source-contract guard for the Gurd proof producer allowlist."""
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
HEADER = ROOT / "AxsCacheKeeperGurdStatus.h"
PRODUCTION_SOURCE = "productionPredicateV1"
PRODUCTION_ALLOWLIST = '@[@"testFixture",@"productionPredicateV1"]'


def require_production_source_allowlist(source):
    if PRODUCTION_ALLOWLIST not in source:
        raise AssertionError(
            "complete Gurd proof projection must recognize productionPredicateV1"
        )


class GurdScopeProjectionContractTests(unittest.TestCase):
    def test_complete_proof_projection_names_production_source(self):
        require_production_source_allowlist(HEADER.read_text(encoding="utf-8"))

    def test_source_mutation_is_rejected_by_contract_guard(self):
        source = HEADER.read_text(encoding="utf-8")
        mutated = source.replace(PRODUCTION_SOURCE, "productionPredicateV2", 1)
        with self.assertRaisesRegex(
            AssertionError, "must recognize productionPredicateV1"
        ):
            require_production_source_allowlist(mutated)


if __name__ == "__main__":
    unittest.main()
