from test.bases import WorldTestBase


class PalworldTestBase(WorldTestBase):
    game = "Palworld"

    def collect_n(self, item_name: str, n: int) -> None:
        """Collects the first n copies of an item (collect_by_name would take every copy). Once per item and test."""
        self.collect(self.get_items_by_name(item_name)[:n])
