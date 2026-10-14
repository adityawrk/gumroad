// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import {
  CircleIntegration,
  CircleIntegrationEditor,
} from "$app/components/ProductEdit/ProductTab/CircleIntegrationEditor";

vi.mock("$app/components/ProductEdit/state", () => ({
  useProductEditContext: () => ({
    product: { native_type: "membership", variants: [] },
    updateProduct: () => {},
  }),
}));

vi.mock("$app/data/circle_integration", () => ({
  fetchCommunities: () => Promise.resolve({ communities: [{ id: 10, name: "Example community" }] }),
  fetchSpaceGroups: () =>
    Promise.resolve({
      spaceGroups: [
        { id: 20, name: "Existing group" },
        { id: 30, name: "Another group" },
      ],
    }),
}));

afterEach(cleanup);

const renderEditor = (initial: CircleIntegration) => {
  const changed = vi.fn();
  const Harness = () => {
    const [integration, setIntegration] = React.useState(initial);
    return (
      <CircleIntegrationEditor
        integration={integration}
        onChange={(next) => {
          changed(next);
          setIntegration(next);
        }}
      />
    );
  };
  render(<Harness />);
  return changed;
};

const existingIntegration = (keepInactiveMembers: boolean): CircleIntegration => ({
  name: "circle",
  api_key: "example-api-token",
  keep_inactive_members: keepInactiveMembers,
  integration_details: { community_id: "10", space_group_id: "20" },
});

describe("Circle integration membership access policy", () => {
  it.each([true, false])("preserves keep_inactive_members=%s when loading the editor", async (keepInactiveMembers) => {
    const changed = renderEditor(existingIntegration(keepInactiveMembers));

    const checkbox = await screen.findByLabelText<HTMLInputElement>("Do not remove Circle access when membership ends");
    expect(checkbox.checked).toBe(keepInactiveMembers);
    expect(changed).toHaveBeenLastCalledWith(existingIntegration(keepInactiveMembers));
  });

  it("keeps the selected retention policy when the seller chooses another space group", async () => {
    const changed = renderEditor(existingIntegration(true));
    await screen.findByLabelText("Select a space group");

    fireEvent.change(screen.getByLabelText("Select a space group"), { target: { value: "30" } });

    expect(changed).toHaveBeenLastCalledWith({
      ...existingIntegration(true),
      integration_details: { community_id: "10", space_group_id: "30" },
    });
    expect(screen.getByLabelText<HTMLInputElement>("Do not remove Circle access when membership ends").checked).toBe(
      true,
    );
  });

  it("preserves an intentional opt-out through another space group change", async () => {
    const changed = renderEditor(existingIntegration(true));
    const checkbox = await screen.findByLabelText("Do not remove Circle access when membership ends");

    fireEvent.click(checkbox);
    fireEvent.change(screen.getByLabelText("Select a space group"), { target: { value: "30" } });

    expect(changed).toHaveBeenLastCalledWith({
      ...existingIntegration(false),
      integration_details: { community_id: "10", space_group_id: "30" },
    });
  });

  it("defaults a newly connected integration to removing access when membership ends", async () => {
    const changed = renderEditor(null);
    fireEvent.click(screen.getByLabelText("Invite your customers to a Circle community"));
    fireEvent.change(screen.getByLabelText("API Token"), { target: { value: "example-api-token" } });
    fireEvent.click(screen.getByRole("button", { name: "Load communities" }));
    await waitFor(() => expect(screen.getByLabelText("Select a community")).toBeDefined());
    fireEvent.change(screen.getByLabelText("Select a community"), { target: { value: "10" } });
    await screen.findByLabelText("Select a space group");
    fireEvent.change(screen.getByLabelText("Select a space group"), { target: { value: "20" } });

    expect(changed).toHaveBeenLastCalledWith(existingIntegration(false));
  });
});
