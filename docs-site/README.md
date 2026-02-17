# Lattice Documentation Site

This is the end-user documentation site for [Lattice](https://github.com/plattegruber/lattice), built with [Astro](https://astro.build/) and [Starlight](https://starlight.astro.build/).

## Local Development

```bash
# Install dependencies
npm install

# Start dev server (http://localhost:4321)
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

## Project Structure

```
docs-site/
├── public/                 # Static assets
├── src/
│   ├── assets/             # Images, etc.
│   └── content/
│       └── docs/           # Documentation pages (Markdown/MDX)
│           ├── concepts/   # Core concepts (Sprites, Intents, Fleet Manager)
│           ├── guides/     # How-to guides (Dashboard, API, Safety, Deployment)
│           ├── index.mdx   # Getting Started
│           └── architecture.md
├── astro.config.mjs        # Astro + Starlight configuration
├── package.json
└── tsconfig.json
```

## Adding Pages

Add Markdown or MDX files to `src/content/docs/`. Update the sidebar configuration in `astro.config.mjs` if you want the page to appear in navigation.

See the [Starlight docs](https://starlight.astro.build/) for more information on customization.
