from decimal import Decimal

from shopcart import Cart, format_receipt
from shopcart.pricing import line_total


def test_exactly_threshold_is_discounted():
    assert line_total(Decimal("2.00"), 10) == Decimal("19.00")


def test_below_threshold_is_not_discounted():
    assert line_total(Decimal("2.00"), 9) == Decimal("18.00")


def test_above_threshold_is_discounted():
    assert line_total(Decimal("2.00"), 11) == Decimal("20.90")


def test_cart_and_receipt_use_discounted_line():
    cart = Cart()
    cart.add("W1", "Widget", "2.00", 10)
    assert cart.subtotal() == Decimal("19.00")
    assert format_receipt(cart).splitlines()[0].endswith("19.00")
