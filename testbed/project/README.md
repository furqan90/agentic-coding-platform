# shopcart

A small shopping-cart library: cart lines, pricing rules and plain-text receipts.

## Layout

| Path | Contents |
|------|----------|
| `src/shopcart/pricing.py` | Money rounding and per-line pricing rules |
| `src/shopcart/cart.py` | `Cart` and `LineItem` |
| `src/shopcart/receipt.py` | `format_receipt(cart)` |
| `tests/` | pytest suite |

## Pricing rules

- Amounts are `decimal.Decimal`, rounded to whole cents, half up.
- A cart line with **10 or more** items gets a **5%** bulk discount on that line.
- The cart subtotal is the sum of the line totals.

## Receipt format

One row per line item, a 36-character `-` separator, then the subtotal:

```
  3 x Widget                    6.00
  1 x Gadget                    5.50
------------------------------------
Subtotal                       11.50
```

Rows are `quantity` right-aligned in 3, ` x `, `name` left-aligned in 20, a space, and the line total right-aligned in 9.

## Running the tests

```
python -m pytest
```
