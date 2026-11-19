# Deployment Guide

This guide explains how to deploy the Jyväskylä Cricket Club website.

## Recommended: Netlify Deployment

### Prerequisites
- A GitHub repository with this code
- A Netlify account (free tier is sufficient)

### Steps

1. **Push code to GitHub**
   ```bash
   git add .
   git commit -m "Modernized JCC website with Astro"
   git push origin main
   ```

2. **Connect to Netlify**
   - Go to [https://app.netlify.com](https://app.netlify.com)
   - Click "Add new site" → "Import an existing project"
   - Choose GitHub and select your repository
   - Netlify will auto-detect the Astro framework

3. **Configure Build Settings** (should be auto-detected)
   - Build command: `npm run build`
   - Publish directory: `dist`
   - Node version: 22

4. **Deploy!**
   - Click "Deploy site"
   - Netlify will build and deploy your site
   - You'll get a temporary URL like `random-name.netlify.app`

5. **Custom Domain Setup**
   - Go to Site settings → Domain management
   - Add custom domain: `cricketjyvaskyla.com`
   - Follow DNS configuration instructions
   - Netlify provides free SSL certificates

### Auto-Deploy
After initial setup, every push to `main` branch will automatically:
- Build the site
- Run checks
- Deploy if successful

## Alternative: Vercel Deployment

Similar to Netlify:
1. Go to [https://vercel.com](https://vercel.com)
2. Import your GitHub repository
3. Vercel auto-detects Astro
4. Deploy!

## Alternative: Traditional Hosting

If using traditional hosting (FTP/cPanel):

1. **Build the site locally**
   ```bash
   npm run build
   ```

2. **Upload the `dist/` folder**
   - The `dist/` folder contains all static files
   - Upload contents to your web server's public directory
   - Usually `public_html/` or `www/`

3. **Important**:
   - Ensure PDF files in `dist/pdfs/` are uploaded
   - Check that `robots.txt` and `sitemap.xml` are in root

### Secured upload script (FTPS)

`scripts/deploy-ftp.sh` builds the site and mirrors `dist/` over FTP with mandatory TLS (explicit FTPS, via lftp). It never sends the password unless TLS is negotiated and the server certificate and hostname verify.

One-time setup (macOS):

```bash
brew install lftp
export FTP_USER=<your-ftp-login>
# Store the password in the Keychain. -T "" makes every read ask for approval
# (choose "Allow", never "Always Allow").
security add-generic-password -a "$FTP_USER" -s jcc-ftp -T "" -w
```

Usage:

```bash
export FTP_USER=<your-ftp-login>
export FTP_REMOTE_DIR=/<web-root>      # folder that holds the live site
scripts/deploy-ftp.sh                  # dry run: summary of files that would change
scripts/deploy-ftp.sh --apply          # upload
scripts/deploy-ftp.sh --apply --delete # also delete remote files not in dist/
```

- Host defaults to `ftps4.us.freehostia.com` (override with `FTP_HOST`).
- Asks for confirmation when not run from `master`.
- Run it in your own terminal, not through an AI agent's shell, so the session transcript never contains deploy output.
- `scripts/test-deploy-ftp.sh` is an offline regression test against a fake FTP server: it checks the password is never sent when the server refuses TLS or presents an untrusted certificate. Run it after changing the deploy script.
- FileZilla: use host `ftps4.us.freehostia.com` with "Require explicit FTP over TLS". Plain FTP sends the password unencrypted.

## Environment Variables

No environment variables needed for basic deployment. All configuration is in `astro.config.mjs`.

## Post-Deployment Checklist

- [ ] Site loads at custom domain
- [ ] All 8 pages are accessible
- [ ] Images load correctly
- [ ] PDFs download properly
- [ ] Navigation works on mobile
- [ ] SSL certificate active (HTTPS)
- [ ] robots.txt accessible at `/robots.txt`
- [ ] sitemap.xml accessible at `/sitemap.xml`
- [ ] Old URLs redirect to new ones (e.g., `/members.html` → `/members`)

## Monitoring

- **Netlify**: Built-in analytics available
- **Google Search Console**: Add your domain for SEO monitoring
- **Google Analytics**: Add tracking code if needed

## Rollback

If you need to rollback:
- **Netlify**: Go to Deploys → select previous deploy → "Publish deploy"
- **Vercel**: Similar rollback in deployments section

## Support

For issues:
- Netlify docs: https://docs.netlify.com
- Astro docs: https://docs.astro.build
- Contact: chairman@cricketjyvaskyla.com
