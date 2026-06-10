# Service logos — simple-icons (CC0)

The SVG icons in this folder are taken from the [simple-icons](https://github.com/simple-icons/simple-icons)
project.

- **License:** CC0 1.0 Universal (public domain) — confirmed from the source
  (`simple-icons/simple-icons` → `LICENSE.md` header reads "CC0 1.0 Universal").
- **Usage:** single-color SVGs; painted with the theme color (`currentColor`/tint)
  in the app. `IssuerAvatar` normalizes the issuer name to a slug and shows the matching SVG;
  if there is no match, it falls back to an initial + colored circle.
- **Curated subset:** to keep the bundle size small, only common services are
  embedded (see `docs/Design.md §6, §7`). All issuers without a match use the fallback.
- **Offline + privacy:** no runtime logo/favicon fetching is performed; all icons come from the bundle.

To add a new icon: download
`https://raw.githubusercontent.com/simple-icons/simple-icons/master/icons/<slug>.svg`,
and place it in this folder (slug = lowercase service name).
