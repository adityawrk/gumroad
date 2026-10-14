// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import { TextInput } from "$app/components/Download/CustomField/TextInput";
import { PurchaseCustomFieldsProvider, PurchaseInfoProvider } from "$app/components/DownloadPage/WithContent";
import { showAlert } from "$app/components/server-components/Alert";

vi.mock("$app/components/server-components/Alert", () => ({ showAlert: vi.fn() }));

const fetchMock = vi.fn<typeof fetch>();

beforeEach(() => {
  vi.stubGlobal("fetch", fetchMock);
  vi.stubGlobal("Routes", { purchase_custom_fields_path: () => "/purchase_custom_fields" });
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
  vi.clearAllMocks();
  fetchMock.mockReset();
});

const renderInput = (type: "shortAnswer" | "longAnswer", value = "") => {
  render(
    <PurchaseInfoProvider value={{ purchaseId: "purchase-1", redirectId: "redirect-1", token: "token-1" }}>
      <PurchaseCustomFieldsProvider value={[{ custom_field_id: "field-1", type, value }]}>
        <TextInput customFieldId="field-1" type={type} label="Your response" />
      </PurchaseCustomFieldsProvider>
    </PurchaseInfoProvider>,
  );
  return screen.getByRole<HTMLInputElement | HTMLTextAreaElement>("textbox", { name: "Your response" });
};

describe.each(["shortAnswer", "longAnswer"] as const)("%s saving", (type) => {
  it.each(["network", "server", "rejected"] as const)(
    "retains the response and permits retry after a %s failure",
    async (failure) => {
      if (failure === "network") fetchMock.mockRejectedValueOnce(new TypeError("Failed to fetch"));
      else fetchMock.mockResolvedValueOnce(new Response(null, { status: failure === "server" ? 500 : 404 }));
      fetchMock.mockResolvedValue(new Response(null, { status: 204 }));
      const input = renderInput(type, "Saved response");
      fireEvent.change(input, { target: { value: "Unsaved response" } });
      fireEvent.blur(input);

      await waitFor(() => expect(input.disabled).toBe(false));
      expect(input.value).toBe("Unsaved response");
      expect(showAlert).toHaveBeenCalledWith(expect.any(String), "error");
      expect(showAlert).not.toHaveBeenCalledWith("Response saved!", "success");

      fireEvent.focus(input);
      fireEvent.blur(input);
      await waitFor(() => expect(showAlert).toHaveBeenCalledWith("Response saved!", "success"));
      expect(fetchMock).toHaveBeenCalledTimes(2);
      expect(JSON.parse(String(fetchMock.mock.lastCall?.[1]?.body))).toEqual({
        purchase_id: "purchase-1",
        custom_field_id: "field-1",
        value: "Unsaved response",
        token: "token-1",
      });

      fireEvent.focus(input);
      fireEvent.blur(input);
      expect(fetchMock).toHaveBeenCalledTimes(2);
    },
  );

  it("keeps the field disabled until the save finishes and remembers successful empty responses", async () => {
    let complete: ((response: Response) => void) | undefined;
    fetchMock.mockImplementationOnce(() => new Promise((resolve) => (complete = resolve)));
    const input = renderInput(type, "Saved response");
    fireEvent.change(input, { target: { value: "" } });
    fireEvent.blur(input);
    expect(input.disabled).toBe(true);

    await act(async () => {
      complete?.(new Response(null, { status: 204 }));
      await Promise.resolve();
    });
    expect(input.disabled).toBe(false);
    expect(showAlert).toHaveBeenCalledWith("Response saved!", "success");
    fireEvent.focus(input);
    fireEvent.blur(input);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("does not save an unchanged response", () => {
    const input = renderInput(type, "Already saved");
    fireEvent.focus(input);
    fireEvent.blur(input);
    expect(fetchMock).not.toHaveBeenCalled();
  });
});
