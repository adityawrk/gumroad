// @vitest-environment happy-dom
import { fireEvent, render, screen, cleanup } from "@testing-library/react";
import { differenceInDays, startOfDay, subDays } from "date-fns";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { DateRangePicker } from "$app/components/DateRangePicker";
import { UserAgentProvider } from "$app/components/UserAgent";

// This must match MAX_HOURLY_DATE_RANGE_DAYS in components/Analytics/index.tsx: ranges spanning
// this many calendar days or fewer unlock the hourly view on the analytics page.
const MAX_HOURLY_DATE_RANGE_DAYS = 7;

const renderPicker = () => {
  const setFrom = vi.fn<(date: Date) => void>();
  const setTo = vi.fn<(date: Date) => void>();
  render(
    <UserAgentProvider value={{ isMobile: false, locale: "en-US" }}>
      <DateRangePicker from={subDays(new Date(), 30)} to={new Date()} setFrom={setFrom} setTo={setTo} />
    </UserAgentProvider>,
  );
  fireEvent.click(screen.getByLabelText("Date range selector"));
  return { setFrom, setTo };
};

const pickedRange = (setFrom: ReturnType<typeof vi.fn<(date: Date) => void>>, setTo: typeof setFrom) => {
  expect(setFrom).toHaveBeenCalledTimes(1);
  expect(setTo).toHaveBeenCalledTimes(1);
  const from = setFrom.mock.calls[0]?.[0];
  const to = setTo.mock.calls[0]?.[0];
  if (!(from instanceof Date) || !(to instanceof Date)) throw new Error("expected Date arguments");
  return { from, to };
};

describe("DateRangePicker presets", () => {
  afterEach(cleanup);

  it("lists Today and Last 7 days first, before Last 30 days", () => {
    renderPicker();
    const labels = screen.getAllByRole("menuitem").map((item) => item.textContent);
    expect(labels.slice(0, 3)).toEqual(["Today", "Last 7 days", "Last 30 days"]);
  });

  it("sets Today to a range from midnight to now", () => {
    const { setFrom, setTo } = renderPicker();
    fireEvent.click(screen.getByText("Today"));
    const { from, to } = pickedRange(setFrom, setTo);
    expect(from).toEqual(startOfDay(new Date()));
    expect(startOfDay(to)).toEqual(startOfDay(new Date()));
    expect(differenceInDays(startOfDay(to), startOfDay(from))).toBeLessThanOrEqual(MAX_HOURLY_DATE_RANGE_DAYS);
  });

  it("sets Last 7 days to a rolling range ending today that stays within the hourly view limit", () => {
    const { setFrom, setTo } = renderPicker();
    fireEvent.click(screen.getByText("Last 7 days"));
    const { from, to } = pickedRange(setFrom, setTo);
    expect(startOfDay(from)).toEqual(startOfDay(subDays(new Date(), 7)));
    expect(startOfDay(to)).toEqual(startOfDay(new Date()));
    // The analytics page only offers the hourly view for ranges spanning at most 7 calendar
    // days (comparing days, not times) — the main reason these presets exist.
    expect(differenceInDays(startOfDay(to), startOfDay(from))).toBeLessThanOrEqual(MAX_HOURLY_DATE_RANGE_DAYS);
  });
});
