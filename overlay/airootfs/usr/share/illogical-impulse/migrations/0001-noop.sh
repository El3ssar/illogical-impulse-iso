#!/usr/bin/env bash
# 0001-noop.sh — the example migration (#27). Demonstrates the NNNN-name.sh
# convention and the migrate runner contract: it is SOURCED by `iictl migrate`
# (so the mutator + ledger_* helpers are already in scope — do NOT re-source
# iictl-common.sh) and must be idempotent. This one does nothing, so it is the
# safe baseline against which `iictl migrate` / `--list` / `--dry-run` are tested.
# Real migrations call the shared mutators (ledger-recorded → reversible) and
# only ever touch distro-owned or user-owned state, never an upstream path.
ok "noop migration: nothing to do"
