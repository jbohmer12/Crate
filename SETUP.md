# Crate cloud setup (about 30 minutes)

Your app lives at https://jbohmer12.github.io/Crate/ . Keep the old `index.html` in the repo until the steps below work, then replace it.

## 1. Supabase project
1. supabase.com > New project. Save the database password somewhere safe. Leave **Enable Data API** checked. "Automatically expose new tables" can stay off, because `schema.sql` grants access itself. Checking **Enable automatic RLS** is a harmless extra safety net.
2. SQL Editor > New query > paste all of `supabase/schema.sql` > Run.
3. Project Settings > API: copy the **Project URL** and the **anon / publishable** key. These two are safe to put in the web page. Never use the `service_role` key there.

## 1b. Friends (run before uploading the new index.html)
SQL Editor > new query > paste all of `supabase/friends.sql` > Run. It adds usernames, friend requests, the trade flag and a per-record "hide from friends" switch.
Friends never read your records table. They only get the safe columns the functions return: title, artist, label, year, cover, condition, how many Discogs collectors own it, and the edition size when it's sourced. Dollar values, what you paid, notes, etching and hidden records are never sent to anyone but you.

## 1c. Crates, wantlist and value history (run before uploading the new index.html)
SQL Editor > new query > paste all of `supabase/features.sql` > Run. It adds gig crates, the wantlist and price history. All of it is private to the owner. Friends never see any of it.

## 2. Sign-in options
Authentication > Providers:
- **Email**: on. While testing with friends you can switch off "Confirm email" so sign-up is instant. Turn it back on before a public launch.
- **Google**: see step 3.

Authentication > URL Configuration:
- Site URL: `https://jbohmer12.github.io/Crate/`
- Redirect URLs: add `https://jbohmer12.github.io/Crate/**`

## 3. Google sign-in
1. console.cloud.google.com > create a project (or reuse one).
2. APIs & Services > OAuth consent screen: app name "Crate", your support email, External. Add yourself as a test user while in Testing. Click Publish app when friends outside the test list need access.
3. Credentials > Create credentials > OAuth client ID > Web application.
   - Authorized JavaScript origins: `https://jbohmer12.github.io`
   - Authorized redirect URIs: `https://<your-project-ref>.supabase.co/auth/v1/callback`
4. Copy the Client ID and Client secret into Supabase > Authentication > Providers > Google, and switch it on.

## 4. Keys and functions
- **Anthropic**: console.anthropic.com > create a NEW key just for Crate, and set a monthly spend limit on the workspace.
- **Discogs**: your personal token (discogs.com/settings/developers). It is used because price suggestions need a seller-enabled account.

```
npm i -g supabase
supabase login
supabase link --project-ref <your-project-ref>
supabase secrets set ANTHROPIC_API_KEY=sk-ant-... DISCOGS_TOKEN=... FREE_SCANS_PER_MONTH=15
supabase functions deploy scan
supabase functions deploy discogs
```
Run the commands from the `crate-cloud` folder. Secrets never go in the repo or the web page.

## 5. Point the app at your project
Open `index.html`, edit the two lines near the top of the script:
```
const SUPABASE_URL = 'https://<your-project-ref>.supabase.co';
const SUPABASE_ANON_KEY = '<anon key>';
```
Upload it to the repo as `index.html` (replace the old one). Wait for the Pages build, open the link, and create your account.

On first login the app offers to import the records saved in your browser from the old version.

## Test checklist
- Create an account with email, sign out, sign in again.
- Continue with Google.
- Forgot password email arrives and lets you set a new one.
- Search NANN001, add it, reload: it should still be there.
- Scan a label. The "free scans left" count should drop by one.
- Sign in with a second account: it must see none of your records.

## Making someone Pro (until payments exist)
SQL Editor: `update profiles set plan = 'pro' where id = (select id from auth.users where email = 'friend@example.com');`

## Before the App Store
- Apple requires an in-app way to delete your account and data.
- Apple also expects Sign in with Apple when an app offers Google sign-in (or an equivalent privacy-focused option). Check the current guideline 4.8.
- Confirm Discogs allows your commercial use before charging for the paid plan.
- Supabase free projects pause after a period of inactivity. Upgrade before relying on it.
