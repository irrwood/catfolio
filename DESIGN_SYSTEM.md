# Catfolio Design System

The current Lab workspace is the reference implementation for Catfolio v5.

## Foundations

| Token | Value | Usage |
|---|---:|---|
| Workspace | `#f7f8fa` | Page and sidebar background |
| Surface | `#ffffff` | Cards, panels, selected controls |
| Soft surface | `#f7f8fa` | Table headers, segmented selections, nested regions |
| Border | `#f1f1f1` | Primary card outline |
| Strong border | `#eaebed` | Controls and focus-adjacent boundaries |
| Text | `#000000` | Titles and primary values |
| Secondary text | `#888888` | Labels and supporting metadata |
| Tertiary text | `#a7a7a7` | Low-priority descriptions |
| Positive | `#2f8a3e` | Gains and positive states |
| Negative | `#e40014` | Losses and destructive states |
| Chart blue | `#708cff` | Cost series and focus rings |

Typography uses the bundled variable Nunito font. Page titles are 30/41, section titles are 18/25, body data is 14/19, and compact labels are 12/16.

## Geometry

- Page padding: 20px 10px on desktop.
- Layout gap: 10px between primary regions.
- Card padding: 20px.
- Primary card radius: 20px.
- Control radius: 8–12px.
- Primary cards use a 1px border and no shadow.

## Components

- Page header: title, one-line scope/status copy, optional actions aligned right.
- Metric card: label, large tabular value, compact supporting line.
- Content card: section title and optional subtitle followed by the working surface.
- Segmented control: soft container, white selected item, no heavy outline.
- Tables: soft rounded header, white rows, right-aligned numeric data, restrained row hover.
- Forms: 40px minimum control height, white surface, strong-border focus state.
- Charts: transparent plotting surface, pale `#EAEBED` grid and pointer lines, no decorative frame inside the card.

## Motion and accessibility

- Standard transitions: 150–220ms ease.
- Motion communicates entry, selection, hover, or data updates only.
- All controls require keyboard focus treatment.
- `prefers-reduced-motion: reduce` removes nonessential transitions and animations.
