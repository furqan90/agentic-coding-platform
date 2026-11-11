# Feature: sales tax on cart totals and receipts

Add sales tax support. Keep the existing behaviour unchanged when no tax region is given.

1. New module `src/shopcart/tax.py`:
   - `TAX_RATES`: a dict of region code to `Decimal` rate: `none` 0, `ca` 0.0725, `ny` 0.08875, `tx` 0.0625.
   - `tax_for(amount, region)`: returns the tax on `amount` as a `Decimal` rounded to whole cents, half up (use `to_money` from `pricing.py`). Region codes are case-insensitive. An unknown region raises `ValueError`.
2. `Cart.total(region="none")`: returns the subtotal plus `tax_for(subtotal, region)`.
3. `format_receipt(cart, region=None)`: with no region the receipt is unchanged. With a region, add two rows after the subtotal, in the same layout as the subtotal row (label left-aligned in 26, a space, amount right-aligned in 9):
   - `Tax (CA)` (the region code in upper case) with the tax amount
   - `Total` with the total
4. Add tests for the new behaviour and document the tax rules in README.md.

Make sure the whole test suite passes (`python -m pytest`).
