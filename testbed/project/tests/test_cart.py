from decimal import Decimal

import pytest

from shopcart import Cart


def test_add_merges_same_sku():
    cart = Cart()
    cart.add("W1", "Widget", "2.00", 2)
    cart.add("W1", "Widget", "2.00", 1)
    assert [(item.sku, item.quantity) for item in cart.lines()] == [("W1", 3)]


def test_remove():
    cart = Cart()
    cart.add("W1", "Widget", "2.00")
    cart.add("G1", "Gadget", "5.50")
    cart.remove("W1")
    assert [item.sku for item in cart.lines()] == ["G1"]


def test_subtotal():
    cart = Cart()
    cart.add("W1", "Widget", "2.00", 3)
    cart.add("B1", "Bolt", "0.99", 2)
    assert cart.subtotal() == Decimal("7.98")


def test_add_rejects_zero_quantity():
    with pytest.raises(ValueError):
        Cart().add("W1", "Widget", "2.00", 0)
