# Repair: receipt tests are failing

`tests/test_receipt.py` fails. The receipt code in `src/shopcart/receipt.py` is correct and matches the receipt format and pricing rules in README.md; the tests were written against an older version of the module and were never updated.

Fix the tests so they check the current, documented behaviour. Do not change anything under `src/`, and do not delete tests or weaken them to trivial assertions. Make sure the whole test suite passes (`python -m pytest`).
