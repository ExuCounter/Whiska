# :needs_nif marks the one thing v0.0.1 cannot currently do — open SQLite from an
# escript, because escript archives carry no priv directory and so cannot carry
# exqlite's NIF. Excluded so the suite reports what genuinely works; the test
# itself documents the conflict with ADR-0030 and is meant to go green once
# packaging is settled. Run it with: mix test --include needs_nif
ExUnit.start(exclude: [:needs_nif])
