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
      social: [
        {
          icon: "github",
          label: "GitHub",
          href: "https://github.com/plattegruber/lattice",
        },
      ],
      sidebar: [
        { label: "Getting Started", slug: "" },
        {
          label: "Concepts",
          items: [
            { label: "Sprites", slug: "concepts/sprites" },
            { label: "Intents", slug: "concepts/intents" },
            { label: "Fleet Manager", slug: "concepts/fleet-manager" },
          ],
        },
        {
          label: "Guides",
          items: [
            { label: "Dashboard", slug: "guides/dashboard" },
            { label: "API Reference", slug: "guides/api" },
            { label: "Safety & Guardrails", slug: "guides/safety" },
            { label: "Deployment", slug: "guides/deployment" },
          ],
        },
        { label: "Architecture", slug: "architecture" },
      ],
      editLink: {
        baseUrl:
          "https://github.com/plattegruber/lattice/edit/main/docs-site/",
      },
    }),
  ],
});
