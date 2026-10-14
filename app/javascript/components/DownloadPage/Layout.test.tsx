// @vitest-environment happy-dom
import { cleanup, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { Layout, LayoutProps } from "$app/components/DownloadPage/Layout";
import { LoggedInUserProvider } from "$app/components/LoggedInUser";

vi.mock("$app/components/useIsAboveBreakpoint", () => ({ useIsAboveBreakpoint: () => true }));

const purchase: NonNullable<LayoutProps["purchase"]> = {
  id: "purchase-1",
  receipt_purchase_id: null,
  email: null,
  email_digest: "",
  is_archived: false,
  has_invoice: false,
  product_id: "product-1",
  product_permalink: null,
  product_name: "Consultation",
  variant_id: null,
  product_long_url: null,
  created_at: "2026-01-01T12:00:00Z",
  allows_review: false,
  product_available: true,
  disable_reviews_after_year: false,
  review: null,
  review_account_name: null,
  membership: null,
  purchase_custom_fields: [],
  call: null,
};

beforeEach(() => {
  vi.stubEnv("TZ", "America/New_York");
  vi.useFakeTimers({ toFake: ["Date"] });
  vi.setSystemTime(new Date("2026-07-01T12:00:00Z"));
  vi.stubGlobal("Routes", { receipt_purchase_url: () => "/purchases/purchase-1/receipt" });
});

afterEach(() => {
  cleanup();
  vi.useRealTimers();
  vi.unstubAllEnvs();
  vi.unstubAllGlobals();
});

const renderCall = (start_time: string, end_time: string, url: string | null = null) =>
  render(
    <LoggedInUserProvider value={null}>
      <Layout
        content_unavailability_reason_code={null}
        is_mobile_app_web_view={false}
        terms_page_url="https://example.com/terms"
        token="token-1"
        redirect_id="redirect-1"
        add_to_library_option="none"
        purchase={{ ...purchase, call: { start_time, end_time, url } }}
      >
        <p>Your call is booked.</p>
      </Layout>
    </LoggedInUserProvider>,
  );

describe("booked call times", () => {
  it("labels a winter booking with its timezone when viewed in summer", () => {
    renderCall("2027-01-15T15:00:00Z", "2027-01-15T16:00:00Z");
    expect(screen.getByRole("heading", { level: 5 }).textContent).toBe("10:00 - 11:00 EST");
    expect(screen.getByText("Friday, January 15, 2027")).toBeDefined();
  });

  it("labels a summer booking with its timezone when viewed in winter", () => {
    vi.setSystemTime(new Date("2026-01-01T12:00:00Z"));
    renderCall("2026-07-15T14:00:00Z", "2026-07-15T15:00:00Z");
    expect(screen.getByRole("heading", { level: 5 }).textContent).toBe("10:00 - 11:00 EDT");
  });

  it.each([
    ["2026-03-08T06:30:00Z", "2026-03-08T07:30:00Z", "01:30 EST - 03:30 EDT"],
    ["2026-11-01T05:30:00Z", "2026-11-01T06:30:00Z", "01:30 EDT - 01:30 EST"],
  ])("labels both endpoints when the call crosses a timezone transition", (startTime, endTime, expected) => {
    renderCall(startTime, endTime);
    expect(screen.getByRole("heading", { level: 5 }).textContent).toBe(expected);
  });

  it("preserves the date range and join link for an overnight call", () => {
    const url = "https://example.com/meeting";
    renderCall("2027-01-16T04:30:00Z", "2027-01-16T05:30:00Z", url);
    expect(screen.getByRole("heading", { level: 5 }).textContent).toBe("23:30 - 00:30 EST");
    expect(screen.getByText("Friday, January 15, 2027 - Saturday, January 16, 2027")).toBeDefined();
    expect(screen.getByRole("link", { name: url }).getAttribute("href")).toBe(url);
  });

  it.each([
    ["Asia/Kolkata", "20:30 - 21:30 GMT+5:30"],
    ["UTC", "15:00 - 16:00 UTC"],
  ])("uses the %s browser timezone without daylight saving", (timeZone, expected) => {
    vi.stubEnv("TZ", timeZone);
    renderCall("2027-01-15T15:00:00Z", "2027-01-15T16:00:00Z");
    expect(screen.getByRole("heading", { level: 5 }).textContent).toBe(expected);
  });
});
