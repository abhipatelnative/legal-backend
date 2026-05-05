import { createHash } from "crypto";

interface ScrapeTestInput {
  placeId?: string;
  maxReviews?: number;
  maxScrolls?: number;
  debugHeaded?: boolean;
  slowMoMs?: number;
  // Backward-compatible optional fields (ignored in Place ID-only mode).
  lat?: number;
  lng?: number;
  apiKey?: string;
  strategy?: string;
}

interface ScrapedGoogleReview {
  review_id: string;
  reviewer_name: string;
  reviewer_photo_url: string | null;
  rating: number | null;
  review_text: string;
  review_time: string | null;
  source: "playwright";
}

interface ScrapeExecutionResult {
  reviews: ScrapedGoogleReview[];
  hasMorePossible: boolean;
  notes: string[];
  placeName?: string | null;
}

interface ScrapeTestResult {
  success: boolean;
  strategy: "playwright";
  resolvedPlaceId: string;
  placeName: string | null;
  totalFetched: number;
  hasMorePossible: boolean;
  notes: string[];
  reviews: ScrapedGoogleReview[];
}

const DEFAULT_MAX_REVIEWS = 120;
const DEFAULT_MAX_SCROLLS = 220;
const DEFAULT_SLOW_MO_MS = 180;

const clamp = (value: number, min: number, max: number): number => Math.min(Math.max(value, min), max);

const safeNumber = (value: unknown): number | undefined => {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
};

const normalizeText = (value: string | null | undefined): string =>
  (value || "").replace(/\s+/g, " ").trim();

const dedupeNotes = (notes: string[]): string[] => {
  const seen = new Set<string>();
  const output: string[] = [];
  for (const note of notes) {
    const normalized = normalizeText(note);
    if (!normalized) continue;
    if (seen.has(normalized)) continue;
    seen.add(normalized);
    output.push(normalized);
  }
  return output;
};

const parseRating = (value: string | null | undefined): number | null => {
  if (!value) return null;
  const match = value.match(/([0-9]+(?:\.[0-9]+)?)/);
  if (!match) return null;
  const parsed = Number(match[1]);
  return Number.isFinite(parsed) ? parsed : null;
};

const buildReviewId = (
  placeId: string,
  reviewerName: string,
  reviewText: string,
  reviewTime: string | null,
  rating: number | null
): string => {
  const seed = [placeId, reviewerName, reviewText, reviewTime || "", rating ?? ""].join("|");
  return createHash("sha1").update(seed).digest("hex");
};

const acceptConsentIfPresent = async (page: any) => {
  const selectors = [
    'button:has-text("Accept all")',
    'button:has-text("I agree")',
    'button:has-text("Reject all")',
  ];
  for (const selector of selectors) {
    const button = page.locator(selector).first();
    if ((await button.count()) > 0) {
      try {
        await button.click({ timeout: 2000 });
        break;
      } catch {
        // Ignore and continue with scraping flow.
      }
    }
  }
};

const hasReviewCards = async (page: any): Promise<boolean> => {
  const articleCount = await page.locator('div[role="article"]').count();
  const reviewIdCount = await page.locator("[data-review-id], [data-reviewid]").count();
  return articleCount > 0 || reviewIdCount > 0;
};

const detectGoogleAntiBotBlock = async (page: any): Promise<string | null> => {
  const currentUrl = String(page.url() || "");
  if (currentUrl.includes("/sorry/")) {
    return "Google anti-bot challenge detected (/sorry/). Reviews are blocked for this request/IP.";
  }

  try {
    const flags = await page.evaluate(() => {
      const text = (document.body?.innerText || "").toLowerCase();
      return {
        unusualTraffic: text.includes("unusual traffic"),
        notRobot: text.includes("not a robot"),
        captcha: text.includes("captcha"),
      };
    });
    if (flags.unusualTraffic || flags.notRobot || flags.captcha) {
      return "Google anti-bot challenge text detected on page. Reviews are blocked for this request/IP.";
    }
  } catch {
    // Ignore probing failures.
  }

  return null;
};

const extractPlaceName = async (page: any): Promise<string | null> => {
  try {
    const value = await page.evaluate(() => {
      const heading =
        (document.querySelector("h1.DUwDvf") as HTMLElement | null)?.innerText ||
        (document.querySelector("h1") as HTMLElement | null)?.innerText ||
        "";
      return heading.trim() || null;
    });
    return typeof value === "string" && value.trim() ? value.trim() : null;
  } catch {
    return null;
  }
};

const openReviewSurfaceByPlaceId = async (
  page: any,
  placeId: string
): Promise<{ opened: boolean; notes: string[] }> => {
  const urls = [
    `https://search.google.com/local/reviews?placeid=${encodeURIComponent(placeId)}`,
    `https://www.google.com/maps/place/?q=place_id:${encodeURIComponent(placeId)}&hl=en`,
    `https://www.google.com/maps/search/?api=1&query=google&query_place_id=${encodeURIComponent(placeId)}&hl=en`,
  ];
  const notes: string[] = [];

  for (const url of urls) {
    try {
      await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
      await acceptConsentIfPresent(page);

      const antiBotMessage = await detectGoogleAntiBotBlock(page);
      if (antiBotMessage) {
        notes.push(antiBotMessage);
        continue;
      }

      if (await hasReviewCards(page)) {
        return { opened: true, notes };
      }

      const reviewButtons = [
        'button[jsaction*="pane.reviewChart.moreReviews"]',
        'button[jsaction*="pane.rating.moreReviews"]',
        'button[aria-label*=" review"]',
        'button[aria-label*=" reviews"]',
        'button:has-text("reviews")',
        'button:has-text("review")',
        'button:has-text("More reviews")',
        'button:has-text("Google reviews")',
      ];

      for (const selector of reviewButtons) {
        const trigger = page.locator(selector).first();
        if ((await trigger.count()) > 0) {
          try {
            await trigger.click({ timeout: 3000 });
            await page.waitForTimeout(900);
            const antiBotAfterClick = await detectGoogleAntiBotBlock(page);
            if (antiBotAfterClick) {
              notes.push(antiBotAfterClick);
              break;
            }
            if (await hasReviewCards(page)) {
              return { opened: true, notes };
            }
          } catch {
            // Try next selector.
          }
        }
      }

      const hasWriteReview = await page.locator('button[aria-label*="Write a review"], button:has-text("Write a review")').count();
      if (hasWriteReview > 0) {
        notes.push("Place page loaded but only 'Write a review' is visible; public review list is not exposed for this place.");
      }
    } catch {
      // Try next URL pattern.
    }
  }

  return {
    opened: false,
    notes: dedupeNotes(
      notes.length
        ? notes
        : ["Could not open Google Maps reviews surface for this Place ID."]
    ),
  };
};

const extractReviewsFromDom = async (page: any, placeId: string): Promise<ScrapedGoogleReview[]> => {
  const extracted = (await page.evaluate(
    ({ targetPlaceId }: { targetPlaceId: string }) => {
      const normalize = (value: string | null | undefined): string =>
        (value || "").replace(/\s+/g, " ").trim();
      const parseRatingText = (value: string | null | undefined): number | null => {
        if (!value) return null;
        const match = value.match(/([0-9]+(?:\.[0-9]+)?)/);
        if (!match) return null;
        const parsed = Number(match[1]);
        return Number.isFinite(parsed) ? parsed : null;
      };

      const pickText = (root: Element, selectors: string[]): string => {
        for (const selector of selectors) {
          const node = root.querySelector(selector) as HTMLElement | null;
          if (node?.innerText) {
            const text = normalize(node.innerText);
            if (text) return text;
          }
        }
        return "";
      };

      const rawCandidates = Array.from(
        document.querySelectorAll('div[role="article"], [data-review-id], [data-reviewid], .jftiEf')
      ) as HTMLElement[];

      const cards: HTMLElement[] = [];
      const seen = new Set<HTMLElement>();

      for (const node of rawCandidates) {
        const card = (node.closest('div[role="article"]') as HTMLElement | null) || node;
        if (!seen.has(card)) {
          seen.add(card);
          cards.push(card);
        }
      }

      return cards.map((card, index) => {
        const reviewerName =
          pickText(card, [".d4r55", "a[class*='WNxzHc']", ".TSUbDb"]) || "Google User";
        const ratingLabel =
          (card.querySelector('span[aria-label*="star"]') as HTMLElement | null)?.getAttribute("aria-label") ||
          (card.querySelector('[role="img"][aria-label*="star"]') as HTMLElement | null)?.getAttribute("aria-label") ||
          "";
        const reviewText = pickText(card, [".wiI7pd", ".MyEned", "span[jsname='bN97Pc']", ".review-full-text"]);
        const reviewTime = pickText(card, [".rsqaWe", ".DU9Pgb"]) || null;
        const reviewerPhotoUrl = (card.querySelector("img") as HTMLImageElement | null)?.src || null;
        const explicitId =
          card.getAttribute("data-review-id") ||
          card.getAttribute("data-reviewid") ||
          card.getAttribute("jslog") ||
          "";

        return {
          review_id: explicitId || `${targetPlaceId}-${index}-${reviewerName}-${reviewTime || ""}-${reviewText.slice(0, 60)}`,
          reviewer_name: reviewerName,
          reviewer_photo_url: reviewerPhotoUrl,
          rating: parseRatingText(ratingLabel),
          review_text: reviewText,
          review_time: reviewTime,
          source: "playwright" as const,
        };
      });
    },
    { targetPlaceId: placeId }
  )) as ScrapedGoogleReview[];

  return extracted;
};

const scrollReviewSurface = async (page: any) => {
  const feed = page.locator('div[role="feed"]').first();
  if ((await feed.count()) > 0) {
    await feed.evaluate((node: any) => {
      node.scrollBy(0, node.scrollHeight || 2800);
    });
    return;
  }

  await page.evaluate(() => {
    const nodes = Array.from(document.querySelectorAll("div")) as HTMLDivElement[];
    const scrollables = nodes
      .filter((node) => {
        const style = window.getComputedStyle(node);
        return (
          (style.overflowY === "auto" || style.overflowY === "scroll") &&
          node.scrollHeight > node.clientHeight + 50
        );
      })
      .sort((a, b) => b.scrollHeight - a.scrollHeight)
      .slice(0, 3);

    for (const node of scrollables) {
      node.scrollBy(0, node.scrollHeight || 2400);
    }
    window.scrollBy(0, window.innerHeight * 1.5);
  });
};

const scrapeWithPlaywright = async (
  placeId: string,
  maxReviews: number,
  maxScrolls: number,
  debugHeaded: boolean,
  slowMoMs: number
): Promise<ScrapeExecutionResult> => {
  let browser: any = null;
  let context: any = null;
  let page: any = null;

  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const playwright = require("playwright") as { chromium?: any };
    if (!playwright?.chromium) {
      throw new Error(
        "Playwright is not installed in Backend. Run: npm install playwright && npx playwright install chromium"
      );
    }

    browser = await playwright.chromium.launch({
      headless: !debugHeaded,
      slowMo: debugHeaded ? slowMoMs : 0,
      args: ["--no-sandbox", "--disable-setuid-sandbox"],
    });
    context = await browser.newContext({ locale: "en-US" });
    page = await context.newPage();

    const surface = await openReviewSurfaceByPlaceId(page, placeId);
    const placeName = await extractPlaceName(page);
    if (!surface.opened) {
      return {
        reviews: [],
        hasMorePossible: false,
        placeName,
        notes: dedupeNotes([
          "Scraping is Place ID based only (no API fallback).",
          debugHeaded ? "Debug visible browser mode was enabled." : "",
          ...surface.notes,
        ]),
      };
    }

    const reviewsById = new Map<string, ScrapedGoogleReview>();
    let stagnantRounds = 0;

    for (let i = 0; i < maxScrolls && reviewsById.size < maxReviews; i += 1) {
      const batch = await extractReviewsFromDom(page, placeId);
      const before = reviewsById.size;

      for (const item of batch) {
        const stableId =
          item.review_id && item.review_id.length > 8
            ? item.review_id
            : buildReviewId(placeId, item.reviewer_name, item.review_text, item.review_time, item.rating);
        const normalizedText = normalizeText(item.review_text);
        if (!reviewsById.has(stableId) && (normalizedText || item.reviewer_name !== "Google User")) {
          reviewsById.set(stableId, {
            ...item,
            review_id: stableId,
            review_text: normalizedText,
            rating: typeof item.rating === "number" ? item.rating : parseRating(String(item.rating || "")),
          });
        }
      }

      if (reviewsById.size === before) {
        stagnantRounds += 1;
      } else {
        stagnantRounds = 0;
      }

      if (stagnantRounds >= 10) {
        break;
      }

      await scrollReviewSurface(page);
      await page.waitForTimeout(750);
    }

    const reviews = Array.from(reviewsById.values()).slice(0, maxReviews);
    return {
      reviews,
      hasMorePossible: reviews.length >= maxReviews,
      placeName,
      notes: dedupeNotes([
        "Scraping is Place ID based only (no API fallback).",
        debugHeaded ? "Debug visible browser mode was enabled." : "",
        "Result depth depends on Google Maps page behavior, anti-bot checks, and lazy-loading limits.",
      ]),
    };
  } catch (error: any) {
    const message = String(error?.message || "Playwright scrape failed.");
    if (debugHeaded && /spawn EPERM|Failed to launch|cannot find Chrome|no display|browserType\\.launch/i.test(message)) {
      throw new Error(
        "Could not launch visible browser. Run backend in an interactive desktop session or disable Debug Visible Browser."
      );
    }
    throw new Error(message);
  } finally {
    try {
      if (page) await page.close();
    } catch {
      // Ignore cleanup errors.
    }
    try {
      if (context) await context.close();
    } catch {
      // Ignore cleanup errors.
    }
    try {
      if (browser) await browser.close();
    } catch {
      // Ignore cleanup errors.
    }
  }
};

export const runGoogleMapsScrapeTest = async (
  input: ScrapeTestInput
): Promise<ScrapeTestResult> => {
  const placeId = typeof input.placeId === "string" ? input.placeId.trim() : "";
  if (!placeId) {
    throw new Error("Google Place ID is required.");
  }

  const maxReviews = clamp(Math.floor(safeNumber(input.maxReviews) || DEFAULT_MAX_REVIEWS), 1, 2000);
  const maxScrolls = clamp(Math.floor(safeNumber(input.maxScrolls) || DEFAULT_MAX_SCROLLS), 20, 5000);
  const debugHeaded = Boolean(input.debugHeaded);
  const slowMoMs = clamp(
    Math.floor(safeNumber(input.slowMoMs) || DEFAULT_SLOW_MO_MS),
    0,
    4000
  );

  const execution = await scrapeWithPlaywright(placeId, maxReviews, maxScrolls, debugHeaded, slowMoMs);

  return {
    success: true,
    strategy: "playwright",
    resolvedPlaceId: placeId,
    placeName: execution.placeName || null,
    totalFetched: execution.reviews.length,
    hasMorePossible: execution.hasMorePossible,
    notes: execution.notes,
    reviews: execution.reviews,
  };
};
