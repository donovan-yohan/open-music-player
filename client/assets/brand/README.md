# Sound Q brand assets

Canonical source:

- `soundq-logo.svg` — flat boxed 三九/SQ mark, orange on black.

Generated assets:

- `soundq-logo.png` — 1024px Flutter/login/splash asset.
- `client/web/favicon.png` and `client/web/icons/*`.
- Android `mipmap-*dpi/ic_launcher.png`.
- Extension icon copies under `extension/icons/` and `extension/assets/`.

Regenerate all generated assets from the SVG:

```bash
python3 scripts/generate_soundq_brand_assets.py
```

Do not reintroduce the old placeholder/glowy mark. The locked direction is matte orange/black, boxed/stamped, no neon, no gradients, no large ivory fields.
