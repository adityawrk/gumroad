// @vitest-environment happy-dom
import { mergeDataIntoQueryString, type ReloadOptions } from "@inertiajs/core";
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import BundlesContentEdit from "$app/pages/Bundles/Content/Edit";
import { assertDefined } from "$app/utils/assert";

vi.stubGlobal("SSR", false);
vi.stubGlobal("Routes", new Proxy({}, { get: () => () => "#" }));

const reload = vi.hoisted(() => vi.fn<(options: ReloadOptions) => void>());
vi.mock("@inertiajs/react", () => ({
  usePage: () => ({
    props: {
      bundle: { name: "Bundle", is_published: false, products: [], custom_permalink: null },
      id: "bundle-id",
      unique_permalink: "bundle",
      products_count: 2,
      has_outdated_purchases: false,
      search_data: { products: [], page: 1, has_more: false },
    },
  }),
  useForm: () => ({ data: { products: [] }, processing: false }),
  router: { reload },
}));
vi.mock("$app/components/BundleEdit/Layout", () => ({
  BundleEditLayout: ({ children }: { children: React.ReactNode }) => children,
  useProductUrl: () => "https://example.com/l/bundle",
}));
vi.mock("$app/components/BundleEdit/ContentTab/BundleProductItem", () => ({ BundleProductItem: () => null }));
vi.mock("$app/components/BundleEdit/ContentTab/BundleProductSelector", () => ({ BundleProductSelector: () => null }));
vi.mock("$app/components/BundleEdit/ContentTab/BundleContentUpdatedStatus", () => ({
  BundleContentUpdatedStatus: () => null,
}));
vi.mock("$app/components/Product/Card", () => ({ Card: () => null }));

beforeEach(() => {
  reload.mockClear();
  window.history.replaceState({}, "", "/bundles/bundle-id/content");
});
afterEach(cleanup);

describe("BundlesContentEdit product search", () => {
  it("clears the previous URL filter when the search input is emptied", async () => {
    render(<BundlesContentEdit />);
    fireEvent.click(screen.getByRole("button", { name: "Add products" }));
    const input = screen.getByPlaceholderText<HTMLInputElement>("Search products");

    fireEvent.change(input, { target: { value: "Included" } });
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
    const [searchedUrl] = mergeDataIntoQueryString(
      "get",
      window.location.href,
      assertDefined(reload.mock.calls[0]?.[0]?.data),
    );
    window.history.replaceState({}, "", searchedUrl);
    expect(new URL(window.location.href).searchParams.get("query")).toBe("Included");

    fireEvent.change(input, { target: { value: "" } });
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(2));
    const [clearedUrl] = mergeDataIntoQueryString(
      "get",
      window.location.href,
      assertDefined(reload.mock.calls[1]?.[0]?.data),
    );

    expect(new URL(clearedUrl).searchParams.get("query")).toBe("");
    expect(input.value).toBe("");
  });

  it("uses the current filter when selecting all products after replacing a search", async () => {
    render(<BundlesContentEdit />);
    fireEvent.click(screen.getByRole("button", { name: "Add products" }));
    const input = screen.getByPlaceholderText("Search products");

    fireEvent.change(input, { target: { value: "First" } });
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
    const [firstUrl] = mergeDataIntoQueryString(
      "get",
      window.location.href,
      assertDefined(reload.mock.calls[0]?.[0]?.data),
    );
    window.history.replaceState({}, "", firstUrl);

    fireEvent.change(input, { target: { value: "Second" } });
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(2));
    const [secondUrl] = mergeDataIntoQueryString(
      "get",
      window.location.href,
      assertDefined(reload.mock.calls[1]?.[0]?.data),
    );
    window.history.replaceState({}, "", secondUrl);
    fireEvent.click(screen.getByRole("checkbox", { name: "All products" }));

    expect(reload).toHaveBeenLastCalledWith(expect.objectContaining({ data: { query: "Second", all: true } }));
  });

  it("selects all without restoring a cleared search filter", async () => {
    render(<BundlesContentEdit />);
    fireEvent.click(screen.getByRole("button", { name: "Add products" }));
    const input = screen.getByPlaceholderText("Search products");

    fireEvent.change(input, { target: { value: "Included" } });
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(1));
    window.history.replaceState({}, "", "/bundles/bundle-id/content?query=Included");
    fireEvent.change(input, { target: { value: "" } });
    await waitFor(() => expect(reload).toHaveBeenCalledTimes(2));
    fireEvent.click(screen.getByRole("checkbox", { name: "All products" }));
    const [allUrl] = mergeDataIntoQueryString(
      "get",
      window.location.href,
      assertDefined(reload.mock.calls[2]?.[0]?.data),
    );

    expect(new URL(allUrl).searchParams.get("query")).toBe("");
    expect(new URL(allUrl).searchParams.get("all")).toBe("true");
  });
});
