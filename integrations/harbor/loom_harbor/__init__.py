"""Run Loom as the agent under test in Harbor (the Terminal-Bench harness).

Harbor loads the agent by import path, so the whole public surface is one
class: `loom_harbor.agent:LoomAgent`. The other modules are the pure halves
that the agent composes, kept free of Harbor imports where they can be so
that they are testable, and readable, without a Harbor install.
"""
