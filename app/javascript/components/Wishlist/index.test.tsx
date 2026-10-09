// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { fetchPaginatedWishlistItems, deleteWishlistItem } from "$app/data/wishlists";

import { Wishlist, type WishlistItem, type WishlistProps } from "$app/components/Wishlist";

vi.mock("$app/data/wishlists", () => ({ fetchPaginatedWishlistItems: vi.fn(), deleteWishlistItem: vi.fn() }));
vi.mock("$app/components/Product/Card", () => ({
  Card: ({ product, footerAction }: { product: WishlistItem["product"]; footerAction: React.ReactNode }) => (
    <div data-testid="wishlist-item">
      <h2>{product.name}</h2>
      {footerAction}
    </div>
  ),
}));
vi.mock("$app/components/Product/CtaButton", () => ({ trackCtaClick: vi.fn() }));
vi.mock("$app/components/CopyToClipboard", () => ({
  CopyToClipboard: ({ children }: React.PropsWithChildren) => children,
}));
vi.mock("$app/components/Wishlist/FollowButton", () => ({ FollowButton: () => null }));
vi.mock("$app/components/Wishlist/WishlistEditor", () => ({ WishlistEditor: () => null }));
vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));
vi.mock("$app/components/WithTooltip", () => ({ WithTooltip: ({ children }: React.PropsWithChildren) => children }));

let serverItems: WishlistItem[];
let intersect: (() => void) | undefined;

const pagination = (page: number): WishlistProps["pagination"] => {
  const pages = Math.max(1, Math.ceil(serverItems.length / 20));
  return {
    count: serverItems.length,
    items: 20,
    page,
    pages,
    prev: page > 1 ? page - 1 : null,
    next: page < pages ? page + 1 : null,
    last: pages,
  };
};

const pageResponse = (page: number) => ({
  items: serverItems.slice((page - 1) * 20, page * 20),
  pagination: pagination(page),
});

const item = (id: number): WishlistItem => ({
  id: id.toString(),
  product: {
    id: id.toString(),
    permalink: `product-${id}`,
    name: `Product ${id}`,
    seller: null,
    ratings: null,
    price_cents: 100,
    currency_code: "usd",
    thumbnail_url: null,
    native_type: "digital",
    url: `https://example.com/l/product-${id}`,
    is_pay_what_you_want: false,
    quantity_remaining: null,
    is_sales_limited: false,
    duration_in_months: null,
    recurrence: null,
  },
  option: null,
  recurrence: null,
  quantity: 1,
  rent: false,
  purchasable: false,
  giftable: false,
  created_at: "2026-10-09T12:00:00Z",
});

const renderWishlist = (count: number) => {
  serverItems = Array.from({ length: count }, (_, i) => item(i + 1));
  render(
    <Wishlist
      id="wishlist"
      name="Reading list"
      description={null}
      url="https://example.com/wishlists/reading-list"
      user={null}
      following={false}
      can_follow={false}
      can_edit
      discover_opted_out={false}
      checkout_enabled={false}
      {...pageResponse(1)}
    />,
  );
};

const loadMore = async () => {
  await act(async () => intersect?.());
};

const remove = async (id: number) => {
  const card = screen.getByRole("heading", { name: `Product ${id}` }).parentElement;
  if (!card) throw new Error("Wishlist card missing");
  await act(async () => fireEvent.click(within(card).getByRole("button", { name: "Remove this product" })));
};

beforeEach(() => {
  intersect = undefined;
  vi.stubGlobal("Routes", { checkout_url: () => "https://example.com/checkout" });
  vi.stubGlobal(
    "IntersectionObserver",
    class {
      constructor(callback: (entries: { isIntersecting: boolean }[]) => void) {
        intersect = () => callback([{ isIntersecting: true }]);
      }
      observe() {}
      disconnect() {}
    },
  );
  vi.mocked(fetchPaginatedWishlistItems).mockReset();
  vi.mocked(deleteWishlistItem).mockReset();
  vi.mocked(fetchPaginatedWishlistItems).mockImplementation(({ page }) => Promise.resolve(pageResponse(page ?? 1)));
  vi.mocked(deleteWishlistItem).mockImplementation(({ wishlistProductId }) => {
    serverItems = serverItems.filter(({ id }) => id !== wishlistProductId);
    return Promise.resolve();
  });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("wishlist pagination after removal", () => {
  it("keeps the first unread item reachable when the next page becomes empty", async () => {
    renderWishlist(21);
    await remove(1);
    await loadMore();
    await loadMore();

    expect(screen.queryByRole("heading", { name: "Product 1" })).toBeNull();
    expect(screen.getByRole("heading", { name: "Product 21" })).toBeDefined();
    expect(screen.getAllByTestId("wishlist-item")).toHaveLength(20);
  });

  it("preserves loaded items while recovering shifted page boundaries", async () => {
    renderWishlist(41);
    await loadMore();
    expect(screen.getAllByTestId("wishlist-item")).toHaveLength(40);
    await remove(25);
    await loadMore();
    await loadMore();
    await loadMore();

    expect(screen.getAllByTestId("wishlist-item")).toHaveLength(40);
    expect(screen.getByRole("heading", { name: "Product 41" })).toBeDefined();
    expect(screen.getAllByRole("heading", { level: 2 }).map(({ textContent }) => textContent)).toEqual(
      serverItems.map(({ product }) => product.name),
    );
  });

  it("ignores a page captured before removal and recovers its shifted item", async () => {
    renderWishlist(41);
    const stalePage = pageResponse(2);
    let finish: ((response: typeof stalePage) => void) | undefined;
    vi.mocked(fetchPaginatedWishlistItems).mockImplementationOnce(
      () =>
        new Promise((resolve) => {
          finish = resolve;
        }),
    );
    await loadMore();
    await remove(1);
    await act(async () => finish?.(stalePage));
    await loadMore();
    await loadMore();

    expect(screen.getAllByTestId("wishlist-item")).toHaveLength(40);
    expect(screen.queryByRole("heading", { name: "Product 1" })).toBeNull();
    expect(screen.getByRole("heading", { name: "Product 21" })).toBeDefined();
    expect(screen.getByRole("heading", { name: "Product 41" })).toBeDefined();
  });

  it("keeps consecutive removals deleted when an earlier refresh finishes late", async () => {
    renderWishlist(21);
    let finish: (() => void) | undefined;
    vi.mocked(fetchPaginatedWishlistItems).mockImplementationOnce(({ page }) => {
      const captured = pageResponse(page ?? 1);
      return new Promise((resolve) => {
        finish = () => resolve(captured);
      });
    });
    await remove(1);
    await loadMore();
    await remove(2);
    await act(async () => finish?.());
    await loadMore();
    await loadMore();

    expect(screen.queryByRole("heading", { name: "Product 1" })).toBeNull();
    expect(screen.queryByRole("heading", { name: "Product 2" })).toBeNull();
    expect(screen.getByRole("heading", { name: "Product 21" })).toBeDefined();
    expect(screen.getAllByTestId("wishlist-item")).toHaveLength(19);
  });

  it("ignores a queued notification from an observer created before removal", async () => {
    renderWishlist(41);
    await loadMore();
    const previousObserver = intersect;
    let finish: (() => void) | undefined;
    vi.mocked(fetchPaginatedWishlistItems).mockImplementationOnce(({ page }) => {
      const captured = pageResponse(page ?? 1);
      return new Promise((resolve) => {
        finish = () => resolve(captured);
      });
    });
    await remove(1);
    await loadMore();
    await act(async () => previousObserver?.());
    expect(fetchPaginatedWishlistItems).toHaveBeenCalledTimes(2);
    await act(async () => finish?.());

    await act(async () => previousObserver?.());
    await loadMore();

    expect(screen.getByRole("heading", { name: "Product 41" })).toBeDefined();
    expect(screen.getAllByTestId("wishlist-item")).toHaveLength(40);
    expect(screen.queryByRole("heading", { name: "Product 1" })).toBeNull();
  });
});
