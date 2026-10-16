// @vitest-environment happy-dom
import { act, cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import CustomDomain from "$app/components/CustomDomain";

let responses: ((response: Response) => void)[];

beforeEach(() => {
  responses = [];
  vi.stubGlobal("Routes", { custom_domain_verifications_path: () => "/custom_domain/verifications" });
  vi.stubGlobal(
    "fetch",
    vi.fn(() => new Promise<Response>((resolve) => responses.push(resolve))),
  );
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const Editor = () => {
  const [domain, setDomain] = React.useState("original.example.com");
  return <CustomDomain verificationStatus={null} customDomain={domain} setCustomDomain={setDomain} label="Domain" />;
};

const resolveVerification = async (index: number, success: boolean, message: string) => {
  const resolve = responses[index];
  if (!resolve) throw new Error(`Missing verification request ${index}`);
  await act(async () => {
    resolve(new Response(JSON.stringify({ success, message }), { status: 200 }));
  });
};

describe("CustomDomain verification", () => {
  it("shows the result for the current domain", async () => {
    render(<Editor />);
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));
    expect(screen.getByRole("button", { name: "Verifying..." })).toHaveProperty("disabled", true);

    await resolveVerification(0, true, "original.example.com domain is correctly configured!");

    expect(screen.queryByRole("button", { name: "Verified!" })).not.toBeNull();
    expect(screen.queryByText("original.example.com domain is correctly configured!")).not.toBeNull();
  });

  it.each([true, false])("discards a stale result after editing the domain (success: %s)", async (success) => {
    render(<Editor />);
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));
    fireEvent.change(screen.getByLabelText("Domain"), { target: { value: "new.example.com" } });

    await resolveVerification(0, success, "Result for original.example.com");

    expect(screen.queryByText("Result for original.example.com")).toBeNull();
    expect(screen.queryByRole("button", { name: "Verified!" })).toBeNull();
    expect(screen.getByRole("button", { name: "Verify" })).toHaveProperty("disabled", false);
  });

  it("keeps a newer verification pending when an older verification finishes", async () => {
    render(<Editor />);
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));
    fireEvent.change(screen.getByLabelText("Domain"), { target: { value: "new.example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));

    await resolveVerification(0, true, "Result for original.example.com");

    expect(screen.getByRole("button", { name: "Verifying..." })).toHaveProperty("disabled", true);
    expect(screen.queryByText("Result for original.example.com")).toBeNull();

    await resolveVerification(1, false, "new.example.com is not configured");
    expect(screen.queryByText("new.example.com is not configured")).not.toBeNull();
    expect(screen.queryByRole("button", { name: "Verified!" })).toBeNull();
  });

  it("discards an old response even if the seller changes back to the original domain", async () => {
    render(<Editor />);
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));
    fireEvent.change(screen.getByLabelText("Domain"), { target: { value: "new.example.com" } });
    fireEvent.change(screen.getByLabelText("Domain"), { target: { value: "original.example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));

    await resolveVerification(1, true, "Latest result");
    await resolveVerification(0, false, "Obsolete result");

    expect(screen.queryByText("Latest result")).not.toBeNull();
    expect(screen.queryByText("Obsolete result")).toBeNull();
    expect(screen.queryByRole("button", { name: "Verified!" })).not.toBeNull();
  });

  it("does not show a previous domain's transport failure while checking the new domain", async () => {
    render(<Editor />);
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));
    fireEvent.change(screen.getByLabelText("Domain"), { target: { value: "new.example.com" } });
    fireEvent.click(screen.getByRole("button", { name: "Verify" }));
    await act(async () => responses[0]?.(new Response("Unavailable", { status: 500 })));

    expect(screen.getByRole("button", { name: "Verifying..." })).toHaveProperty("disabled", true);
    expect(screen.queryByText("Something went wrong.")).toBeNull();

    await resolveVerification(1, true, "new.example.com domain is correctly configured!");
    expect(screen.queryByText("new.example.com domain is correctly configured!")).not.toBeNull();
  });
});
