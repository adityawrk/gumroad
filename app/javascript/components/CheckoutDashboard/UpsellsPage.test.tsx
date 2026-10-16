// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import UpsellsPage, { UpsellsPageProps } from "$app/components/CheckoutDashboard/UpsellsPage";
import { showAlert } from "$app/components/server-components/Alert";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/components/LoggedInUser", () => ({
  useLoggedInUser: () => ({ policies: { upsell: { create: true } } }),
}));
vi.mock("$app/components/CheckoutDashboard/CheckoutPreview", () => ({ CheckoutPreview: () => null }));

type PendingRequest = {
  resolve: (response: Response) => void;
  reject: (reason: Error) => void;
  signal: AbortSignal | null | undefined;
};
let pending: PendingRequest[];

const props: UpsellsPageProps = {
  pages: [],
  products: [],
  pagination: { page: 1, pages: 2 },
  upsells: [
    {
      id: "upsell-id",
      name: "Course upgrade",
      text: "Upgrade your course",
      description: "",
      universal: false,
      cross_sell: true,
      replace_selected_products: false,
      offer_matching_version: false,
      paused: false,
      product: { id: "product-id", name: "Advanced course", currency_type: "usd", variant: null },
      discount: null,
      selected_products: [],
      upsell_variants: [],
    },
  ],
};

beforeEach(() => {
  pending = [];
  vi.clearAllMocks();
  vi.stubGlobal("Routes", new Proxy({}, { get: (_target, name: string) => () => `/${name}` }));
  vi.stubGlobal(
    "fetch",
    vi.fn((url: string, init?: RequestInit) =>
      url === "/paged_checkout_upsells_path"
        ? new Promise<Response>((resolve, reject) => pending.push({ resolve, reject, signal: init?.signal }))
        : Promise.resolve(
            new Response(
              JSON.stringify({ uses: { total: 1, selected_products: {}, upsell_variants: {} }, revenue_cents: 100 }),
            ),
          ),
    ),
  );
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const respond = async (index: number, status: number) => {
  const request = pending[index];
  if (!request) throw new Error(`Missing request ${index}`);
  await act(async () => {
    request.resolve(new Response(JSON.stringify({ upsells: props.upsells, pagination: props.pagination }), { status }));
  });
};

describe("UpsellsPage list loading", () => {
  it.each([500, 403, "network failure"])("restores the existing table after %s and permits a retry", async (status) => {
    render(<UpsellsPage {...props} />);
    fireEvent.click(screen.getByRole("columnheader", { name: /^Revenue/u }));
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(true);

    if (typeof status === "number") await respond(0, status);
    else await act(async () => pending[0]?.reject(new TypeError("Network failure")));

    expect(showAlert).toHaveBeenCalledWith("Something went wrong.", "error");
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(false);
    expect(screen.queryByText("Course upgrade")).not.toBeNull();
    fireEvent.click(screen.getByText("Course upgrade"));
    expect(screen.queryByRole("button", { name: "Pause upsell" })).not.toBeNull();
    fireEvent.click(screen.getByRole("button", { name: "Close" }));
    fireEvent.click(screen.getByRole("columnheader", { name: /^Revenue/u }));
    await respond(1, 200);
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(false);
  });

  it("keeps a newer load busy when an aborted older request settles", async () => {
    render(<UpsellsPage {...props} />);
    fireEvent.click(screen.getByRole("columnheader", { name: /^Revenue/u }));
    fireEvent.click(screen.getByRole("columnheader", { name: /^Uses/u }));
    expect(pending[0]?.signal?.aborted).toBe(true);

    await act(async () => pending[0]?.reject(new DOMException("Aborted", "AbortError")));

    expect(showAlert).not.toHaveBeenCalled();
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(true);
    await respond(1, 200);
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(false);
  });

  it("ignores a late failure for a superseded load", async () => {
    render(<UpsellsPage {...props} />);
    fireEvent.click(screen.getByRole("columnheader", { name: /^Revenue/u }));
    fireEvent.click(screen.getByRole("columnheader", { name: /^Uses/u }));

    await respond(0, 500);

    expect(showAlert).not.toHaveBeenCalled();
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(true);
    await respond(1, 200);
    expect(screen.getByRole("table", { name: "Upsells" }).classList.contains("pointer-events-none")).toBe(false);
  });

  it("does not let a stale successful load overwrite the latest rows", async () => {
    render(<UpsellsPage {...props} />);
    fireEvent.click(screen.getByRole("columnheader", { name: /^Revenue/u }));
    fireEvent.click(screen.getByRole("columnheader", { name: /^Uses/u }));
    await act(async () =>
      pending[1]?.resolve(
        new Response(
          JSON.stringify({ upsells: [{ ...props.upsells[0], name: "Latest course" }], pagination: props.pagination }),
        ),
      ),
    );
    await respond(0, 200);

    expect(screen.queryByText("Latest course")).not.toBeNull();
    expect(screen.queryByText("Course upgrade")).toBeNull();
  });
});
