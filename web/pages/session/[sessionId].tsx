import { useRouter } from 'next/router';
import { useEffect, useState } from 'react';
import dynamic from 'next/dynamic';
import { supabase } from '../../lib/supabaseClient';

const RerunViewer = dynamic(async () => {
  const mod = await import('@rerun-io/web-viewer');
  return mod.WebViewer;
}, { ssr: false });

export default function SessionViewer() {
  const router = useRouter();
  const { sessionId } = router.query;
  const [recordingUrl, setRecordingUrl] = useState<string | null>(null);

  useEffect(() => {
    async function fetchData() {
      if (!sessionId) return;
      const path = `${sessionId}/rerun_sessions.json`;
      const { data, error } = await supabase.storage.from('sessions').download(path);
      if (error) {
        console.error('Error downloading session', error);
      } else if (data) {
        const url = URL.createObjectURL(data);
        setRecordingUrl(url);
      }
    }
    fetchData();
  }, [sessionId]);

  return (
    <main style={{ padding: '1rem' }}>
      <h1>Session: {sessionId}</h1>
      {recordingUrl ? (
        <RerunViewer recording={recordingUrl} style={{ width: '100%', height: '80vh' }} />
      ) : (
        <p>Loading...</p>
      )}
    </main>
  );
}
