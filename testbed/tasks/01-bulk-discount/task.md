# Bug: bulk discount missing at exactly 10 items

A customer bought exactly 10 Widgets at 2.00 each and was charged 20.00. Per the pricing rules in README.md, a line with 10 or more items gets a 5% discount, so the line should have been 19.00. Orders of 11 or more items are discounted correctly.

Fix the bug, add a regression test for the 10-item case, and make sure the whole test suite passes (`python -m pytest`).
