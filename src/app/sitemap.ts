// app/sitemap.ts
import type { MetadataRoute } from 'next';

export default function sitemap(): MetadataRoute.Sitemap {
  const base = 'https://edgeenglish.kr';
  const now = new Date();

  return [
    { url: `${base}/`, lastModified: now, priority: 1.0 },
    { url: `${base}/books`, lastModified: now, priority: 0.8 },
    { url: `${base}/events`, lastModified: now, priority: 0.9 },
    { url: `${base}/faq`, lastModified: now, priority: 0.6 },
    { url: `${base}/notice`, lastModified: now, priority: 0.8 },
    { url: `${base}/price`, lastModified: now, priority: 0.7 },
    { url: `${base}/reviews`, lastModified: now, priority: 0.8 },
    { url: `${base}/tutors`, lastModified: now, priority: 0.7 },
  ];
}
