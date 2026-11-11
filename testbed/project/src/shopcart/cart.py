"""Shopping cart."""
from dataclasses import dataclass
from decimal import Decimal

from shopcart.pricing import line_total, to_money


@dataclass
class LineItem:
    sku: str
    name: str
    unit_price: Decimal
    quantity: int

    @property
    def total(self) -> Decimal:
        return line_total(self.unit_price, self.quantity)


class Cart:
    def __init__(self) -> None:
        self._items: dict[str, LineItem] = {}

    def add(self, sku: str, name: str, unit_price, quantity: int = 1) -> None:
        """Add items; adding an existing SKU increases its quantity."""
        if quantity <= 0:
            raise ValueError("quantity must be positive")
        if sku in self._items:
            self._items[sku].quantity += quantity
        else:
            self._items[sku] = LineItem(sku, name, Decimal(unit_price), quantity)

    def remove(self, sku: str) -> None:
        del self._items[sku]

    def lines(self) -> list[LineItem]:
        return list(self._items.values())

    def subtotal(self) -> Decimal:
        return to_money(sum((item.total for item in self._items.values()), Decimal("0")))
