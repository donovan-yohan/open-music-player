"""Candidate-assembly arms.

Each arm implements ``orchestrator.CandidateAssembler``. Heavy, network-facing
dependencies (langchain / deepagents) are imported lazily inside the model arms,
so importing this package never pulls in the optional ``live`` dependency stack.
"""
