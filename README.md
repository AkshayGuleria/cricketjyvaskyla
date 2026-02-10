<div align="center">
  <img src="public/images/jcc_logo.jpg" alt="Jyväskylä Cricket Club Logo" width="200" />

  # Jyväskylä Cricket Club

  **Official Website - Modernized with Astro**

  [![Built with Astro](https://astro.badg.es/v2/built-with-astro/tiny.svg)](https://astro.build)
  [![Deployed on Netlify](https://img.shields.io/badge/Deployed%20on-Netlify-00C7B7?style=flat&logo=netlify)](https://www.netlify.com)

  [Visit Website](https://cricketjyvaskyla.com) • [Join Us](https://cricketjyvaskyla.com/join_us) • [Contact](https://cricketjyvaskyla.com/contact)
</div>

---

## 📖 About

Jyväskylä Cricket Club (JCC) is a Finnish sports association founded on June 3, 2009, promoting cricket in Central Finland. We welcome both experienced players and complete beginners to join our community.

### 🏏 Quick Facts
- **Founded:** June 3, 2009 (MMVIII)
- **Location:** Jyväskylä, Central Finland
- **Home Ground:** Tikkakosken Liikuntapuisto
- **Members:** 32 active members (2025)
- **Season:** May - September (outdoor), September - April (indoor)

---

## 🚀 This Website

This is a modern, fully responsive website built with [Astro](https://astro.build) - a blazing-fast static site generator.

### ✨ Features

- 🎨 **Modern Design** - Clean, responsive interface with cricket-themed colors
- 📱 **Mobile-First** - Works perfectly on all devices (320px - 3840px)
- ⚡ **Lightning Fast** - Static generation for optimal performance
- ♿ **Accessible** - WCAG AA compliant with keyboard navigation
- 🔍 **SEO Optimized** - Sitemap, meta tags, and structured data
- 📸 **Photo Gallery** - Powered by Photoswipe 5
- 🎯 **Component-Based** - Easy to maintain and update

### 🛠️ Tech Stack

- **Framework:** [Astro 5](https://astro.build)
- **Styling:** Modern CSS with custom properties
- **Gallery:** [Photoswipe 5](https://photoswipe.com)
- **Deployment:** [Netlify](https://netlify.com)
- **Package Manager:** npm

---

## 📂 Project Structure

```
cricketjyvaskyla/
├── src/
│   ├── components/       # Reusable Astro components
│   │   ├── Header.astro
│   │   ├── Footer.astro
│   │   ├── MemberCard.astro
│   │   └── Gallery.astro
│   ├── layouts/          # Page layouts
│   │   └── BaseLayout.astro
│   ├── pages/            # Website pages
│   │   ├── index.astro   # Home
│   │   ├── members.astro # Member directory
│   │   ├── join_us.astro # Membership info
│   │   ├── fixtures.astro
│   │   ├── gallery.astro
│   │   ├── contact.astro
│   │   └── expense_form.astro
│   ├── styles/           # Global styles
│   │   └── global.css
│   └── data/             # Structured data (JSON)
│       ├── members.json
│       └── gallery.json
├── public/               # Static assets
│   ├── images/
│   ├── pdfs/
│   └── robots.txt
└── dist/                 # Production build (generated)
```

---

## 🚦 Getting Started

### Prerequisites

- [Node.js](https://nodejs.org/) (v20 or higher)
- npm (comes with Node.js)

### Installation

```bash
# Clone the repository
git clone https://github.com/AkshayGuleria/cricketjyvaskyla.git
cd cricketjyvaskyla

# Install dependencies
npm install

# Start development server
npm run dev
```

Visit `http://localhost:4321` to see the site locally.

### Build for Production

```bash
# Create production build
npm run build

# Preview production build
npm run preview
```

---

## 📝 Available Scripts

| Command | Description |
|---------|-------------|
| `npm run dev` | Start development server with hot reload |
| `npm run build` | Build site for production |
| `npm run preview` | Preview production build locally |
| `npm run astro` | Run Astro CLI commands |

---

## 📄 Pages

- **Home** - Club history and welcome message
- **Members** - Executive committee and player roster
- **Join Us** - Membership information and fees
- **Fixtures** - Match schedule (updated seasonally)
- **Gallery** - Photo albums from matches and events
- **Contact** - Get in touch with club leadership
- **Expense Form** - Submit expense reports

---

## 🎨 Customization

### Update Member Data

Edit `src/data/members.json`:

```json
{
  "executive": [
    {
      "name": "Name",
      "role": "Position",
      "email": "email@example.com"
    }
  ],
  "players": [...]
}
```

### Add Photos to Gallery

Edit `src/data/gallery.json`:

```json
{
  "albums": [
    {
      "id": "album-id",
      "title": "Album Title",
      "images": [
        {
          "src": "/images/photo.jpg",
          "width": 1920,
          "height": 1080,
          "caption": "Photo caption"
        }
      ]
    }
  ]
}
```

### Modify Styles

Global styles are in `src/styles/global.css` using CSS custom properties:

```css
:root {
  --color-primary: #003580;    /* Finnish blue */
  --color-secondary: #2D5016;  /* Cricket green */
  --color-accent: #DC143C;     /* Cricket ball red */
}
```

---

## 🚀 Deployment

### Deploy to Netlify (Recommended)

1. Push your code to GitHub
2. Sign in to [Netlify](https://app.netlify.com)
3. Click "Add new site" → "Import from Git"
4. Select your repository
5. Netlify auto-detects Astro configuration
6. Click "Deploy site"

**Custom Domain:**
- Add your domain in Netlify settings
- Update DNS records as instructed
- Free SSL certificate auto-enabled

Full deployment instructions: See [`DEPLOYMENT.md`](DEPLOYMENT.md)

### Alternative Deployment Options

- **Vercel:** Similar to Netlify
- **GitHub Pages:** Free static hosting
- **Traditional Hosting:** Upload `dist/` folder via FTP

---

## 📚 Documentation

- [**DEPLOYMENT.md**](DEPLOYMENT.md) - Complete deployment guide
- [**TESTING.md**](TESTING.md) - Testing checklist and guidelines
- [**CLAUDE.md**](CLAUDE.md) - Project instructions for AI assistance

---

## 🤝 Contributing

We welcome contributions! Here's how you can help:

1. **Report Issues** - Found a bug? [Open an issue](https://github.com/AkshayGuleria/cricketjyvaskyla/issues)
2. **Suggest Features** - Have an idea? We'd love to hear it
3. **Submit Pull Requests** - Contributions are welcome
4. **Update Content** - Help keep member info and fixtures current

### Development Workflow

```bash
# Create a feature branch
git checkout -b feature/your-feature-name

# Make your changes
# ...

# Commit with descriptive message
git commit -m "Add: your feature description"

# Push to GitHub
git push origin feature/your-feature-name

# Create Pull Request on GitHub
```

---

## 📞 Contact

- **Chairman:** [chairman@cricketjyvaskyla.com](mailto:chairman@cricketjyvaskyla.com)
- **Secretary:** [secretary@cricketjyvaskyla.com](mailto:secretary@cricketjyvaskyla.com)
- **Website:** [cricketjyvaskyla.com](https://cricketjyvaskyla.com)

---

## 📜 License

This project is maintained by Jyväskylä Cricket Club.

### Credits

- **Original Design:** [ramblingsoul](http://ramblingsoul.com)
- **Modernization:** Akshay Guleria
- **Built with:** [Astro](https://astro.build)
- **Powered by:** [Netlify](https://netlify.com)

---

## 🏏 Join Us!

Interested in playing cricket in Central Finland?

- **Full Membership:** €100/year (earning >€1500/month)
- **Half Membership:** €50/year (students, earning <€1500/month)

👉 [Learn more about joining](https://cricketjyvaskyla.com/join_us)

---

<div align="center">

  **Jyväskylä Cricket Club** • *Founded 2009 (MMVIII)*

  Made with ❤️ in Finland 🇫🇮

</div>
