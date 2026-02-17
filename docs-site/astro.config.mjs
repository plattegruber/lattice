import { defineConfig } from "astro/config";
import starlight from "@astrojs/starlight";

// https://astro.build/config
export default defineConfig({
  site: "https://plattegruber.github.io",
  base: "/lattice",
  integrations: [
    starlight({
      title: "Lattice",
      description:
        "Control plane for managing AI coding agents (Sprites). Real-time fleet operations with safety guardrails.",
      social: {
        github: "https://github.com/plattegruber/lattice",
      },
      sidebar: [
        { label: "Getting Started", link: "/" },
        {
          label: "Concepts",
          autogenerate: { directory: "concepts" },
        },
        {
          label: "Guides",
          autogenerate: { directory: "guides" },
        },
        { label: "Architecture", link: "/architecture/" },
      ],
      editLink: {
        baseUrl:
          "https://github.com/plattegruber/lattice/edit/main/docs-site/",
      },
    }),
  ],
});
