// @ts-check

import {themes as prismThemes} from 'prism-react-renderer';

/** @type {import('@docusaurus/types').Config} */
const config = {
  title: 'Maccheroni',
  tagline: 'Field notes from building local mixed-language transcription on Apple Silicon.',
  favicon: 'img/logo.svg',
  url: 'https://gigio1023.github.io',
  baseUrl: '/maccheroni/',
  organizationName: 'gigio1023',
  projectName: 'maccheroni',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  markdown: {
    format: 'mdx',
    hooks: {
      onBrokenMarkdownLinks: 'throw',
      onBrokenMarkdownImages: 'throw'
    }
  },
  i18n: {
    defaultLocale: 'en',
    locales: ['en']
  },
  presets: [
    [
      'classic',
      /** @type {import('@docusaurus/preset-classic').Options} */
      ({
        docs: false,
        blog: {
          routeBasePath: 'journal',
          path: 'blog',
          blogTitle: 'Maccheroni field notes',
          blogDescription: 'Measured model choices, local runtimes, and the limits of what each experiment establishes.',
          blogSidebarCount: 'ALL',
          showReadingTime: true,
          authorsMapPath: 'authors.yml',
          editUrl: 'https://github.com/gigio1023/maccheroni/edit/main/site/',
          feedOptions: {
            type: ['rss', 'atom'],
            copyright: `Copyright © ${new Date().getFullYear()} gigio1023`
          }
        },
        theme: {
          customCss: './src/css/custom.css'
        }
      })
    ]
  ],
  themeConfig: {
    image: 'img/social-card.png',
    metadata: [
      {name: 'theme-color', content: '#f5efe2'},
      {name: 'keywords', content: 'Apple Silicon, speech recognition, diarization, MLX, local AI'}
    ],
    colorMode: {
      defaultMode: 'light',
      respectPrefersColorScheme: true
    },
    navbar: {
      title: 'Maccheroni',
      logo: {
        alt: 'Maccheroni waveform mark',
        src: 'img/logo.svg'
      },
      items: [
        {to: '/journal', label: 'Journal', position: 'left'},
        {href: 'https://github.com/gigio1023/maccheroni#readme', label: 'Project', position: 'left'},
        {href: 'https://github.com/gigio1023/maccheroni', label: 'GitHub', position: 'right'}
      ]
    },
    footer: {
      style: 'dark',
      links: [
        {
          title: 'Read',
          items: [
            {label: 'Field notes', to: '/journal'},
            {label: 'Project README', href: 'https://github.com/gigio1023/maccheroni#readme'},
            {label: 'Research digest', href: 'https://github.com/gigio1023/maccheroni/blob/main/docs/research-digest.md'}
          ]
        },
        {
          title: 'Source',
          items: [
            {label: 'Repository', href: 'https://github.com/gigio1023/maccheroni'},
            {label: 'License', href: 'https://github.com/gigio1023/maccheroni/blob/main/LICENSE'}
          ]
        }
      ],
      copyright: `Copyright © ${new Date().getFullYear()} gigio1023. Built with Docusaurus.`
    },
    prism: {
      theme: prismThemes.github,
      darkTheme: prismThemes.dracula
    }
  }
};

export default config;
