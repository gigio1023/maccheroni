# Maccheroni research journal

This directory contains the English Docusaurus site published at
<https://gigio1023.github.io/maccheroni/>. The journal explains measured model
choices, candidate research, and the evidence boundaries around both.

## Local development

Use Node.js 20 or newer.

```sh
npm ci
npm run start
```

Build the production site with:

```sh
npm run build
```

The pull-request workflow builds changes under `site/`. After a change reaches
`main`, the Pages workflow builds this directory and deploys `site/build`.
GitHub Pages uses the repository's `/maccheroni/` base path, so check links and
assets through that path when serving the production build locally.

## Editorial boundary

Model-card capabilities are upstream claims until a pinned artifact passes the
repository's fixtures and runtime gates. Keep shipped measurements, withdrawn
routes, research candidates, and incomplete conversions visibly distinct in
every post.
