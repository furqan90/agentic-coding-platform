from decimal import Decimal

import pytest

from shopcart import Cart, format_receipt
from shopcart.tax import TAX_RATES, tax_for


def make_cart():
    cart = Cart()
    cart.add("W1", "Widget", "2.00", 3)
    cart.add("G1", "Gadget", "4.00", 1)
    return cart  # subtotal 10.00


def test_rates():
    assert TAX_RATES["none"] == Decimal("0")
    assert TAX_RATES["ca"] == Decimal("0.0725")
    assert TAX_RATES["ny"] == Decimal("0.08875")
    assert TAX_RATES["tx"] == Decimal("0.0625")


def test_tax_rounds_half_up_to_cents():
    assert tax_for(Decimal("10.00"), "ca") == Decimal("0.73")
    assert tax_for(Decimal("10.00"), "ny") == Decimal("0.89")
    assert tax_for(Decimal("0.00"), "tx") == Decimal("0.00")


def test_region_is_case_insensitive():
    assert tax_for(Decimal("10.00"), "CA") == Decimal("0.73")


def test_unknown_region_rejected():
    with pytest.raises(ValueError):
        tax_for(Decimal("10.00"), "zz")
    with pytest.raises(ValueError):
        make_cart().total("zz")


def test_cart_total():
    cart = make_cart()
    assert cart.total() == Decimal("10.00")
    assert cart.total("ny") == Decimal("10.89")


def test_receipt_without_region_unchanged():
    assert format_receipt(make_cart()).splitlines()[-1] == "Subtotal                       10.00"
    assert len(format_receipt(make_cart()).splitlines()) == 4


def test_receipt_with_region():
    lines = format_receipt(make_cart(), region="ca").splitlines()
    assert lines[-3:] == [
        "Subtotal                       10.00",
        "Tax (CA)                        0.73",
        "Total                          10.73",
    ]
