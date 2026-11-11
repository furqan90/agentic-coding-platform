"""Plain-text receipts."""
from shopcart.cart import Cart

WIDTH = 36


def format_receipt(cart: Cart) -> str:
    rows = [f"{item.quantity:>3} x {item.name:<20} {item.total:>9}" for item in cart.lines()]
    rows.append("-" * WIDTH)
    rows.append(f"{'Subtotal':<26} {cart.subtotal():>9}")
    return "\n".join(rows)
