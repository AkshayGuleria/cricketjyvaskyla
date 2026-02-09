# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is the official website for Jyväskylä Cricket Club (JCC), a Finnish sports association founded in 2009. The website is a static HTML/CSS/JavaScript site with no build process or package management.

## Architecture

### Site Structure

The website uses a **component-based JavaScript injection pattern** for shared elements:
- `js/header.js` - Dynamically generates the header and navigation menu using `document.write()`
- `js/footer.js` - Dynamically generates the footer
- Each HTML page includes these scripts to maintain consistent navigation and branding

### Navigation System

The site uses the **LavaLamp jQuery plugin** for animated navigation:
- Animation effect configured in each HTML page's `<script>` block
- Current page detection via URL parsing in `header.js` (lines 3-6)
- Active menu item marked with `class="current"`

### Page Layout Pattern

All pages follow this structure:
```html
#wrap
  #topbg (decorative)
  #wrap2 (main container with background image)
    [header.js injection point]
    #content
      #left (main content area, 650px)
        .post (repeatable content blocks)
      #sidebar (right sidebar, positioned at 658px)
    [footer.js injection point]
  #btmbg (decorative)
```

### Styling System

- `style.css` - Main stylesheet with fixed-width layout (973px)
- `lavalamp.css` - Navigation animation styles
- Background images define the visual design (header.jpg, footer.jpg, pagebg.png, etc.)

## Key Pages

- `index.html` - Home page with club history
- `join_us.html` - Membership information and fees
- `members.html` - Member directory
- `fixtures.html` - Match schedules
- `gallery.html` - Photo gallery
- `contact.html` - Contact information
- `expense_form.html` - Financial management

## Development Workflow

### Making Changes

**No build process is required.** Simply edit HTML, CSS, or JS files directly.

### Testing Changes

Open HTML files directly in a browser:
```bash
open index.html
# or
python3 -m http.server 8000  # Then visit http://localhost:8000
```

### Navigation Menu Updates

When adding/removing pages, update `js/header.js`:
1. Add/remove the page detection block (lines 14-43)
2. Maintain the pattern: check if current page matches, add `class="current"` if so

### Content Updates

For content changes:
- Main content goes in `#left .post .postcontent` sections
- Sidebar content managed via `js/links.js` and `js/events.js`

## Technical Constraints

### Legacy Dependencies

- jQuery 1.1.3.1 (from 2007)
- XHTML 1.0 Strict doctype
- ISO-8859-1 character encoding (not UTF-8)
- Uses `document.write()` for component injection (not modern practice)
- HTTP feeds (mixed content warning in modern browsers)

### Browser Compatibility

The site targets older browser standards. Modern updates should:
- Test in multiple browsers
- Avoid ES6+ JavaScript features
- Maintain jQuery 1.x compatibility

## Important Notes

- **No automated deployment** - Changes must be manually uploaded to hosting
- The site has no build system, transpilation, or minification
- Images are stored in `/images/` directory
- PDFs (AGM minutes, bylaws, tournament info) stored in subdirectories: `agms/`, `by-laws/`, `smviikko2024/`
- Character encoding issues: Use HTML entities for special characters (e.g., `&Auml;` for Ä)
