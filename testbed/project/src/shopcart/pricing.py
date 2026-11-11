"""Money helpers and per-line pricing rules."""
from decimal import ROUND_HALF_UP, Decimal

CENT = Decimal("0.01")
BULK_THRESHOLD = 10  # lines with this many items or more get the bulk discount
BULK_DISCOUNT = Decimal("0.05")


def to_money(value) -> Decimal:
    """Round to whole cents, half up."""
    return Decimal(value).quantize(CENT, rounding=ROUND_HALF_UP)


def line_total(unit_price: Decimal, quantity: int) -> Decimal:
    """Total for one cart line, after the bulk discount."""
    if quantity < 0:
        raise ValueError("quantity cannot be negative")
    subtotal = Decimal(unit_price) * quantity
    if quantity > BULK_THRESHOLD:
        subtotal -= subtotal * BULK_DISCOUNT
    return to_money(subtotal)
