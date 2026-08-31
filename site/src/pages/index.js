import clsx from 'clsx';
import Link from '@docusaurus/Link';
import Layout from '@theme/Layout';
import Heading from '@theme/Heading';
import styles from './index.module.css';

const routes = [
  {
    role: 'Korean ASR',
    model: 'VibeVoice ASR 8-bit',
    note: 'The measured default for mixed Korean and English with free-text glossary context.',
    state: 'Product'
  },
  {
    role: 'Italian and mixed ASR',
    model: 'MOSS 0.9B MLX INT8',
    note: 'Instruction hotwords, bounded 120-second leaves, and typed recovery.',
    state: 'Product'
  },
  {
    role: 'Speaker timeline',
    model: 'Community-1 Core ML',
    note: 'One whole-file pass remains the only authority for speaker identity.',
    state: 'Product'
  },
  {
    role: 'Speech research',
    model: 'Qwen3 ASR, ForcedAligner, and DiCoW',
    note: 'Separate candidates with distinct parity, timestamp, and dataset gates.',
    state: 'Research'
  }
];

const principles = [
  ['Decode with context', 'Glossary terms reach each ASR model in its native prompt or hotword form.'],
  ['Keep speaker authority global', 'Chunk-local labels never overwrite the whole-file diarization timeline.'],
  ['Fail before losing speech', 'Backend limits and incomplete output become typed failures instead of shorter transcripts.']
];

function RouteList() {
  return (
    <div className={styles.routeList}>
      {routes.map((route) => (
        <article className={styles.route} key={route.role}>
          <div>
            <p className={styles.routeRole}>{route.role}</p>
            <Heading as="h3">{route.model}</Heading>
          </div>
          <p>{route.note}</p>
          <span className={clsx(styles.state, route.state === 'Research' && styles.stateResearch)}>{route.state}</span>
        </article>
      ))}
    </div>
  );
}

function HomePage() {
  return (
    <>
      <header className={styles.hero}>
        <div className={clsx('container', styles.heroGrid)}>
          <div className={styles.heroCopy}>
            <p className={styles.eyebrow}>Local speech research on Apple Silicon</p>
            <Heading as="h1">One pipeline. Different models. Explicit boundaries.</Heading>
            <p className={styles.lead}>Maccheroni is a local transcription workbench for mixed-language conversations. These field notes explain which model owns each job, what the fixtures measured, and where the evidence stops.</p>
            <div className={styles.actions}>
              <Link className={styles.primaryAction} to="/journal/bounding-speech-models-on-apple-silicon">Read the first note</Link>
              <Link className={styles.secondaryAction} href="https://github.com/gigio1023/maccheroni">Inspect the project</Link>
            </div>
          </div>
          <figure className={styles.heroFigure}>
            <img src="img/banner.png" alt="A waveform crossed by two speaker lines and pieces of macaroni" />
            <figcaption>Mixed language, separate speaker evidence, one local machine.</figcaption>
          </figure>
        </div>
      </header>

      <main>
        <section className={styles.routesSection} aria-labelledby="routes-title">
          <div className="container">
            <div className={styles.sectionHeading}>
              <p className={styles.eyebrow}>Current routes</p>
              <Heading as="h2" id="routes-title">Model names follow the job</Heading>
              <p>The product pins models by exact identity and keeps research candidates outside the shipped path until their own evidence closes.</p>
            </div>
            <RouteList />
          </div>
        </section>

        <section className={styles.noteSection} aria-labelledby="note-title">
          <div className={clsx('container', styles.noteGrid)}>
            <div>
              <p className={styles.eyebrow}>Field note 01</p>
              <Heading as="h2" id="note-title">Different Models for Different Jobs in a Local Transcription Pipeline</Heading>
            </div>
            <div className={styles.noteBody}>
              <p>VibeVoice, MOSS, Community-1, Parakeet, Qwen, DiCoW, and a Whisper control answer different questions. This note follows the measurements that shaped their current roles and the conditions that could change them.</p>
              <Link to="/journal/bounding-speech-models-on-apple-silicon">Read the note <span aria-hidden="true">→</span></Link>
            </div>
          </div>
        </section>

        <section className={styles.principlesSection} aria-labelledby="principles-title">
          <div className="container">
            <p className={styles.eyebrow}>Three durable rules</p>
            <Heading as="h2" id="principles-title">Evidence before promotion</Heading>
            <div className={styles.principles}>
              {principles.map(([title, text], index) => (
                <div className={styles.principle} key={title}>
                  <span>{String(index + 1).padStart(2, '0')}</span>
                  <Heading as="h3">{title}</Heading>
                  <p>{text}</p>
                </div>
              ))}
            </div>
          </div>
        </section>
      </main>
    </>
  );
}

export default function Home() {
  return (
    <Layout title="Field notes" description="Measured model choices and local speech research for Maccheroni on Apple Silicon.">
      <HomePage />
    </Layout>
  );
}
