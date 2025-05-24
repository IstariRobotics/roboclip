import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabaseClient';
import dynamic from 'next/dynamic';

interface SessionFile {
  name: string;
  id: string;
}

const RerunViewer = dynamic(async () => {
  const mod = await import('@rerun-io/web-viewer');
  return mod.WebViewer;
}, { ssr: false });

export default function Home() {
  const [sessions, setSessions] = useState<SessionFile[]>([]);
  const [selected, setSelected] = useState<string | null>(null);
  const [recordingUrl, setRecordingUrl] = useState<string | null>(null);

  useEffect(() => {
    async function fetchSessions() {
      const { data, error } = await supabase.storage.from('sessions').list('', { limit: 100 });
      if (error) {
        console.error('Error fetching sessions', error);
      } else {
        setSessions(data as any);
      }
    }
    fetchSessions();
  }, []);

  useEffect(() => {
    async function fetchRecording() {
      if (!selected) return;
      const path = `${selected}/rerun_sessions.json`;
      const { data, error } = await supabase.storage.from('sessions').download(path);
      if (error) {
        console.error('Error downloading session', error);
        setRecordingUrl(null);
      } else if (data) {
        const url = URL.createObjectURL(data);
        setRecordingUrl(url);
      }
    }
    fetchRecording();
    return () => {
      if (recordingUrl) URL.revokeObjectURL(recordingUrl);
    };
  }, [selected]);

  return (
    <div style={{ display: 'flex', height: '100vh' }}>
      <aside style={{ width: 250, overflowY: 'auto', borderRight: '1px solid #ccc', padding: '1rem' }}>
        <h2>Sessions</h2>
        <ul style={{ listStyle: 'none', padding: 0 }}>
          {sessions.map((s) => (
            <li key={s.name}>
              <button
                onClick={() => setSelected(s.name)}
                style={{
                  background: 'none',
                  border: 'none',
                  padding: '0.5rem 0',
                  cursor: 'pointer',
                  textAlign: 'left',
                  width: '100%'
                }}
              >
                {s.name}
              </button>
            </li>
          ))}
        </ul>
      </aside>
      <main style={{ flex: 1, padding: '1rem' }}>
        {selected ? (
          recordingUrl ? (
            <RerunViewer recording={recordingUrl} style={{ width: '100%', height: '100%' }} />
          ) : (
            <p>Loading...</p>
          )
        ) : (
          <p>Select a session to view.</p>
        )}
      </main>
    </div>
  );
}
