from __future__ import annotations


def test_package_imports():
    import scripts.feed_discovery as fd
    assert fd is not None


def test_feedmine_verify_reachable():
    # The pipeline reuses feedmine_verify; it must import from repo root.
    from feedmine_verify import scanner
    assert hasattr(scanner, "scan_directory")
