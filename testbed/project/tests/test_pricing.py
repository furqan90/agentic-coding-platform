from decimal import Decimal

import pytest

from shopcart.pricing import line_total, to_money


def test_single_item():
    assert line_total(Decimal("2.50"), 1) == Decimal("2.50")


def test_small_quantity_has_no_discount():
    assert line_total(Decimal("2.00"), 3) == Decimal("6.00")


def test_large_quantity_gets_bulk_discount():
    assert line_total(Decimal("2.00"), 20) == Decimal("38.00")


def test_negative_quantity_rejected():
    with pytest.raises(ValueError):
        line_total(Decimal("1.00"), -1)


def test_to_money_rounds_half_up():
    assert to_money(Decimal("1.005")) == Decimal("1.01")
