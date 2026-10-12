# Extended-hours status icons

- SF Symbols: `sunrise.fill` for pre-market, `sunset.fill` for after-hours.
- Native symbols use the existing market-status badge's icon size and tint.
- Runtime component: `MarketClosedBadge`, in `HoldingDetailHeader`'s existing
  metadata row. A current pre-market or after-hours quote replaces the moon
  and closed label with the corresponding symbol and session label.
- Extended prices and changes use the existing main quote area. There is no
  second quote row. Chart selections override the live readout until released.
- The 1D plot includes the latest market day's pre-market, regular and
  after-hours prints, including a single opening print. Longer ranges use the
  latest extended price for their displayed endpoint, while stored daily
  closes and portfolio valuations retain their regular-session basis.
- `ExtendedHoursHeaderTests` verifies badge placement,
  main quote selection, both languages/appearances, and large text.
