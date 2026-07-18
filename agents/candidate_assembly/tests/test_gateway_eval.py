from __future__ import annotations

from dataclasses import dataclass

import pytest

from candidate_assembly.budgets import Budget, BudgetExceeded
from candidate_assembly.evalrunner import gateway as gateway_mod
from candidate_assembly.fixture_tools import ToolError
from candidate_assembly.schemas import GatewayCandidate, GatewayCatalogEntry, GatewayEvidence


@dataclass
class _Trace:
    tool: str
    elapsedMs: int = 1


class FakeGateway:
    def __init__(
        self,
        *,
        error: Exception | None = None,
        extract_error: Exception | None = None,
        candidates=None,
        catalog=None,
    ):
        self.error = error
        self.extract_error = extract_error
        self.tool_calls = 0
        self.trace = []
        self.extract_calls = 0
        self.candidates = candidates if candidates is not None else [
            GatewayCandidate(
                candidateId="youtube:official",
                provider="youtube",
                title="Artist - Song Official Audio",
                downloadable=True,
                durationMs=200_000,
                evidenceRefs=["evidence:official"],
            )
        ]
        self.catalog = catalog if catalog is not None else [
            GatewayCatalogEntry(kind="track", id="catalog:track", title="Artist - Song", durationMs=180_000)
        ]

    def search_sources(self, _query, _providers=None, _limit=10):
        self.tool_calls += 1
        self.trace.append(_Trace("search_sources", self.tool_calls))
        if self.error:
            raise self.error
        return self.candidates

    def search_catalog(self, _query, _kind="track", _limit=8):
        self.tool_calls += 1
        self.trace.append(_Trace("search_catalog", self.tool_calls))
        return self.catalog

    def extract_web(self, _ref):
        self.extract_calls += 1
        self.tool_calls += 1
        if self.extract_error:
            raise self.extract_error
        return GatewayEvidence(evidenceRef="evidence:official", text="safe bounded evidence")


def test_gateway_corpus_has_exactly_the_six_reviewed_cases():
    corpus = gateway_mod.load_gateway_corpus()
    assert [case.id for case in corpus.cases] == [
        "official-audio",
        "explicit-request",
        "explicit-remix",
        "soundcloud-only",
        "ambiguous-catalog-title",
        "cross-provider-duration-mismatch",
    ]


def test_gateway_case_reports_only_safe_counts_and_duration_mismatch():
    case = gateway_mod.load_gateway_corpus().cases[0]
    outcome = gateway_mod.run_gateway_case(case, FakeGateway(), Budget.default())
    record = outcome.record()
    assert outcome.terminal == "completed"
    assert outcome.duration_mismatch_observed is True
    assert record["sourceCount"] == 1
    assert record["providerCounts"] == {"youtube": 1}
    assert record["toolDurationsMs"] == {"search_sources": 1, "search_catalog": 1}
    rendered = str(record)
    assert "Official Audio" not in rendered
    assert "evidence:official" not in rendered


@pytest.mark.parametrize(
    ("error", "expected"),
    [
        (ToolError("FIRECRAWL_DISABLED", "never record URL https://private.test"), "FIRECRAWL_DISABLED"),
        (ToolError("FIRECRAWL_TIMEOUT", "timeout"), "FIRECRAWL_TIMEOUT"),
        (ToolError("FIRECRAWL_RATE_LIMIT", "rate"), "FIRECRAWL_RATE_LIMIT"),
        (ToolError("FIRECRAWL_RESPONSE_TOO_LARGE", "oversize"), "FIRECRAWL_RESPONSE_TOO_LARGE"),
    ],
)
def test_firecrawl_experiment_reports_typed_failure_without_output(error, expected):
    case = gateway_mod.load_gateway_corpus().cases[0]
    box = FakeGateway(extract_error=error)
    record = gateway_mod.run_firecrawl_experiment(box, case, Budget.default(), enabled=True)
    assert record["terminal"] == "failed"
    assert record["errorCode"] == expected
    assert record["firecrawlRequests"] == 0
    assert record["outputStored"] is False
    assert box.extract_calls == 1
    assert "private.test" not in str(record)


def test_firecrawl_experiment_is_disabled_by_default_and_cancelled_before_extract():
    case = gateway_mod.load_gateway_corpus().cases[0]
    box = FakeGateway()
    disabled = gateway_mod.run_firecrawl_experiment(box, case, Budget.default(), enabled=False)
    assert disabled["terminal"] == "disabled"
    assert box.extract_calls == 0

    cancelled = gateway_mod.run_firecrawl_experiment(box, case, Budget.default(), enabled=True, cancelled=lambda: True)
    assert cancelled["terminal"] == "cancelled"
    assert box.extract_calls == 0


def test_firecrawl_experiment_caps_success_at_one_request_credit_and_job():
    case = gateway_mod.load_gateway_corpus().cases[0]
    box = FakeGateway()
    record = gateway_mod.run_firecrawl_experiment(box, case, Budget.default(), enabled=True)
    assert record["terminal"] == "completed"
    assert (record["firecrawlRequests"], record["firecrawlCredits"], record["firecrawlJobs"]) == (1, 1, 1)
    assert box.extract_calls == 1


def test_gateway_case_reports_budget_exhaustion_and_deterministic_fallback():
    case = gateway_mod.load_gateway_corpus().cases[0]
    outcome = gateway_mod.run_gateway_case(case, FakeGateway(error=BudgetExceeded("BUDGET_EXCEEDED", "budget")), Budget.default())
    assert outcome.terminal == "failed"
    assert outcome.budget == "exhausted"
    assert outcome.fallback == "deterministic_baseline"


def test_gateway_records_keep_the_selected_case_set_and_disabled_firecrawl_totals():
    corpus = gateway_mod.load_gateway_corpus()
    outcome = gateway_mod.run_gateway_case(corpus.cases[0], FakeGateway(), Budget.default())
    firecrawl = gateway_mod.run_firecrawl_experiment(FakeGateway(), corpus.cases[0], Budget.default(), enabled=False)
    records = gateway_mod.build_gateway_records(corpus, [outcome], firecrawl=firecrawl, run_state="warm")
    assert records[0]["run"]["cases"] == ["official-audio"]
    assert records[0]["run"]["runState"] == "warm"
    assert records[-1]["totals"]["firecrawlRequests"] == 0
