from shopcart import Cart
from shopcart.receipt import render_receipt


def make_cart():
    cart = Cart()
    cart.add("W1", "Widget", "2.00", 3)
    cart.add("G1", "Gadget", "5.50", 1)
    return cart


def test_one_row_per_item_plus_total():
    lines = render_receipt(make_cart()).splitlines()
    assert len(lines) == 3


def test_total_row():
    last = render_receipt(make_cart()).splitlines()[-1]
    assert last == "Total: 11.50"


def test_bulk_row_shows_amount():
    cart = Cart()
    cart.add("B1", "Bolt", "1.00", 12)
    assert render_receipt(cart).splitlines()[0].endswith("12.00")
