# Roboclip Web Viewer

This Next.js app lists Roboclip sessions stored in Supabase and lets you visualize them using [rerun.io](https://www.rerun.io/) right in the browser. The dashboard shows a scrollable list of sessions on the left and loads the selected session in the viewer on the right.

## Setup

1. Install dependencies:
   ```bash
   npm install
   ```
2. Create a `.env.local` file with your Supabase credentials:
   ```env
   NEXT_PUBLIC_SUPABASE_URL=your-supabase-url
   NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-key
   ```
3. Run the development server:
   ```bash
   npm run dev
   ```

Deploy the `web` folder to Vercel like any other Next.js project.

The app expects a Supabase storage bucket named `sessions`. Each session should contain a `rerun_sessions.json` file generated with the Python tools. Selecting a session will download this file and pass it to the rerun web viewer.
