# OVP engine fixtures for the CI smoke test.
#
# The engine needs no fixtures from the repository: CI renders a synthetic image with
# Pillow at run time (see .github/workflows/ci.yml) so that no screenshot — and therefore
# no private screen content — is ever committed.
#
# For local manual checks, `tests/run_scenarios.sh` produces its own captures under /tmp.
