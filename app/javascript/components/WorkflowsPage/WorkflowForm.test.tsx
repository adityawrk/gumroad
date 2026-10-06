// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { Workflow, WorkflowFormContext } from "$app/types/workflow";

import WorkflowForm from "$app/components/WorkflowsPage/WorkflowForm";

const requests = vi.hoisted(() => {
  vi.stubGlobal("Routes", new Proxy({}, { get: (_, name: string) => () => `/${name}` }));
  return { post: vi.fn(), patch: vi.fn() };
});

vi.mock("@inertiajs/react", () => ({
  Link: ({ href, children }: { href: string; children: React.ReactNode }) => <a href={href}>{children}</a>,
  useForm: () => {
    let payload: unknown;
    return {
      processing: false,
      transform: (transform: () => unknown) => {
        payload = transform();
      },
      post: (url: string) => requests.post(url, payload),
      patch: (url: string) => requests.patch(url, payload),
    };
  },
}));

vi.mock("$app/components/WorkflowsPage", () => ({
  Layout: ({ actions, children }: { actions: React.ReactNode; children: React.ReactNode }) => (
    <>
      {actions}
      {children}
    </>
  ),
  EditPageNavigation: () => null,
  PublishButton: () => null,
  sendToPastCustomersCheckboxLabel: () => "Also send to past customers",
}));

const context: WorkflowFormContext = {
  products_and_variant_options: [],
  affiliate_product_options: [],
  timezone: "UTC",
  currency_symbol: "$",
  currency_type: "usd",
  countries: [],
  aws_access_key_id: "key",
  s3_url: "https://s3.example.com/bucket",
  user_id: "seller-1",
  gumroad_address: "Test address",
  email_from: "Seller <seller@example.com>",
  eligible_for_abandoned_cart_workflows: true,
};

const workflow: Workflow = {
  name: "Price-filtered workflow",
  external_id: "workflow-1",
  workflow_type: "seller",
  workflow_trigger: null,
  published: false,
  first_published_at: null,
  send_to_past_customers: false,
  installments: [],
  paid_more_than: "0.50",
  paid_less_than: "1,234.56",
};

afterEach(() => {
  cleanup();
  requests.post.mockClear();
  requests.patch.mockClear();
});

describe("WorkflowForm price filters", () => {
  it("preserves decimal bounds when a draft workflow is renamed", () => {
    render(<WorkflowForm context={context} workflow={workflow} />);
    expect(screen.getByLabelText<HTMLInputElement>("Paid more than").value).toBe("0.50");
    expect(screen.getByLabelText<HTMLInputElement>("Paid less than").value).toBe("1234.56");

    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Renamed workflow" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));

    expect(requests.patch).toHaveBeenCalledWith("/workflow_path", {
      workflow: expect.objectContaining({
        name: "Renamed workflow",
        paid_more_than: "0.50",
        paid_less_than: "1234.56",
        unchanged_price_filters: ["paid_more_than", "paid_less_than"],
      }),
    });
  });

  it("submits exactly the decimal prices entered in a new workflow", () => {
    render(<WorkflowForm context={context} />);
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "New workflow" } });
    fireEvent.change(screen.getByLabelText("Paid more than"), { target: { value: "1.15" } });
    fireEvent.change(screen.getByLabelText("Paid less than"), { target: { value: "10.99" } });
    fireEvent.click(screen.getByRole("button", { name: "Save and continue" }));

    expect(requests.post).toHaveBeenCalledWith("/workflows_path", {
      workflow: expect.objectContaining({
        paid_more_than: "1.15",
        paid_less_than: "10.99",
        unchanged_price_filters: [],
      }),
    });
  });

  it("marks only the untouched price bound for preservation when the other bound is edited or cleared", () => {
    render(<WorkflowForm context={context} workflow={workflow} />);
    fireEvent.change(screen.getByLabelText("Paid more than"), { target: { value: "0.75" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(requests.patch).toHaveBeenLastCalledWith("/workflow_path", {
      workflow: expect.objectContaining({
        paid_more_than: "0.75",
        paid_less_than: "1234.56",
        unchanged_price_filters: ["paid_less_than"],
      }),
    });

    fireEvent.change(screen.getByLabelText("Paid more than"), { target: { value: "" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(requests.patch).toHaveBeenLastCalledWith("/workflow_path", {
      workflow: expect.objectContaining({
        paid_more_than: null,
        paid_less_than: "1234.56",
        unchanged_price_filters: ["paid_less_than"],
      }),
    });
  });

  it.each([
    { original: "0.50", selectionEnd: 4, merged: "1,234", expected: "1234" },
    { original: "12.34", selectionEnd: 2, merged: "1,234.34", expected: "1234.34" },
  ])(
    "preserves a grouped price paste with the existing selection in $original",
    ({ original, selectionEnd, merged, expected }) => {
      render(<WorkflowForm context={context} workflow={{ ...workflow, paid_more_than: original }} />);
      const input = screen.getByLabelText<HTMLInputElement>("Paid more than");
      input.setSelectionRange(0, selectionEnd);
      const useDefaultPaste = fireEvent.paste(input, { clipboardData: { getData: () => "1,234" } });
      if (useDefaultPaste) fireEvent.change(input, { target: { value: merged } });

      expect(input.value).toBe(expected);
      fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
      expect(requests.patch).toHaveBeenCalledWith("/workflow_path", {
        workflow: expect.objectContaining({
          paid_more_than: expected,
          paid_less_than: "1234.56",
          unchanged_price_filters: ["paid_less_than"],
        }),
      });
    },
  );

  it("shows disabled USD price bounds while preserving them during a rename when exchange rates are unavailable", () => {
    render(
      <WorkflowForm
        context={{ ...context, currency_type: "eur", currency_symbol: "€" }}
        workflow={{
          ...workflow,
          paid_more_than: "0.50",
          paid_less_than: "1.15",
          price_filter_currency: "usd",
          price_filters_available: false,
        }}
      />,
    );
    expect(screen.getByLabelText<HTMLInputElement>("Paid more than").disabled).toBe(true);
    expect(screen.getByLabelText<HTMLInputElement>("Paid less than").disabled).toBe(true);
    expect(screen.getByLabelText<HTMLInputElement>("Paid more than").value).toBe("0.50");
    expect(screen.getByLabelText<HTMLInputElement>("Paid less than").value).toBe("1.15");
    expect(screen.getByRole("alert").textContent).toContain("USD");

    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Renamed while rates unavailable" } });
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(requests.patch).toHaveBeenCalledWith("/workflow_path", {
      workflow: expect.objectContaining({
        name: "Renamed while rates unavailable",
        unchanged_price_filters: ["paid_more_than", "paid_less_than"],
      }),
    });
  });

  it.each([
    {
      currency: "jpy",
      available: true,
      lower: "225",
      upper: "525",
      nextCurrency: "usd",
      nextLower: "1.50",
      nextUpper: "3.50",
    },
    {
      currency: "usd",
      available: false,
      lower: "1.50",
      upper: "3.50",
      nextCurrency: "jpy",
      nextLower: "225",
      nextUpper: "525",
    },
  ] as const)(
    "keeps $currency amounts and edit availability together across a preserved failed-save render",
    ({ currency, available, lower, upper, nextCurrency, nextLower, nextUpper }) => {
      const priceWorkflow: Workflow = {
        ...workflow,
        paid_more_than: lower,
        paid_less_than: upper,
        price_filter_currency: currency,
        price_filters_available: available,
      };
      const { rerender } = render(
        <WorkflowForm context={{ ...context, currency_type: "jpy" }} workflow={priceWorkflow} />,
      );
      rerender(
        <WorkflowForm
          context={{ ...context, currency_type: "jpy" }}
          workflow={{
            ...priceWorkflow,
            paid_more_than: nextLower,
            paid_less_than: nextUpper,
            price_filter_currency: nextCurrency,
            price_filters_available: !available,
          }}
        />,
      );

      expect(screen.getByLabelText<HTMLInputElement>("Paid more than").value).toBe(lower);
      expect(screen.getByLabelText<HTMLInputElement>("Paid less than").value).toBe(upper);
      expect(screen.getByLabelText<HTMLInputElement>("Paid more than").disabled).toBe(!available);
      expect(screen.getByLabelText<HTMLInputElement>("Paid less than").disabled).toBe(!available);
      expect(screen.getAllByText(currency === "jpy" ? "¥" : "$")).toHaveLength(2);
      fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
      expect(requests.patch).toHaveBeenCalledWith("/workflow_path", {
        workflow: expect.objectContaining({
          paid_more_than: lower,
          paid_less_than: upper,
          unchanged_price_filters: ["paid_more_than", "paid_less_than"],
        }),
      });
    },
  );

  it("rejects a grouped decimal paste that would add a second decimal separator", () => {
    render(<WorkflowForm context={context} workflow={{ ...workflow, paid_more_than: "12.34" }} />);
    const input = screen.getByLabelText<HTMLInputElement>("Paid more than");
    input.setSelectionRange(0, 2);
    const useDefaultPaste = fireEvent.paste(input, { clipboardData: { getData: () => "1,234.56" } });
    if (useDefaultPaste) fireEvent.change(input, { target: { value: "1,234.56.34" } });

    expect(input.value).toBe("12.34");
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(requests.patch).toHaveBeenCalledWith("/workflow_path", {
      workflow: expect.objectContaining({
        paid_more_than: "12.34",
        unchanged_price_filters: ["paid_more_than", "paid_less_than"],
      }),
    });
  });

  it.each(["1.14", "0"])("rejects an upper bound of %s below the lower bound and permits clearing it", (upperBound) => {
    render(<WorkflowForm context={context} />);
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "New workflow" } });
    fireEvent.change(screen.getByLabelText("Paid more than"), { target: { value: "1.15" } });
    fireEvent.change(screen.getByLabelText("Paid less than"), { target: { value: upperBound } });
    fireEvent.click(screen.getByRole("button", { name: "Save and continue" }));
    expect(requests.post).not.toHaveBeenCalled();

    fireEvent.change(screen.getByLabelText("Paid less than"), { target: { value: "" } });
    fireEvent.click(screen.getByRole("button", { name: "Save and continue" }));
    expect(requests.post).toHaveBeenCalledWith("/workflows_path", {
      workflow: expect.objectContaining({ paid_more_than: "1.15", paid_less_than: null }),
    });
  });

  it("keeps zero bounds and zero-decimal currencies in their major units", () => {
    render(
      <WorkflowForm
        context={{ ...context, currency_symbol: "¥", currency_type: "jpy" }}
        workflow={{ ...workflow, paid_more_than: "0", paid_less_than: "1,234" }}
      />,
    );
    expect(screen.getByLabelText<HTMLInputElement>("Paid more than").value).toBe("0");
    expect(screen.getByLabelText<HTMLInputElement>("Paid less than").value).toBe("1234");
    fireEvent.click(screen.getByRole("button", { name: "Save changes" }));
    expect(requests.patch).toHaveBeenCalledWith("/workflow_path", {
      workflow: expect.objectContaining({ paid_more_than: "0", paid_less_than: "1234" }),
    });
  });
});
