from shopcart import Cart, format_receipt


def make_cart():
    cart = Cart()
    cart.add("W1", "Widget", "2.00", 3)
    cart.add("G1", "Gadget", "5.50", 1)
    return cart


def test_one_row_per_item_then_separator_and_subtotal():
    lines = format_receipt(make_cart()).splitlines()
    assert lines == [
        "  3 x Widget                    6.00",
        "  1 x Gadget                    5.50",
        "------------------------------------",
        "Subtotal                       11.50",
    ]


def test_bulk_row_shows_discounted_amount():
    cart = Cart()
    cart.add("B1", "Bolt", "1.00", 12)
    assert format_receipt(cart).splitlines()[0].endswith("11.40")
