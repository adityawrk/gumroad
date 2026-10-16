// @vitest-environment happy-dom
import { cleanup, fireEvent, render, screen, within } from "@testing-library/react";
import * as React from "react";
import { afterEach, describe, expect, it, vi } from "vitest";

import { assertDefined } from "$app/utils/assert";

import { RatingSelector } from "$app/components/RatingSelector";

afterEach(cleanup);

describe("rating selection", () => {
  it("lets a keyboard user focus a star before choosing a rating", () => {
    render(<RatingSelector currentRating={null} onChangeCurrentRating={vi.fn()} />);

    const star = screen.getByRole<HTMLElement>("radio", { name: "1 star" });
    expect(star.tabIndex).toBeGreaterThanOrEqual(0);
    star.focus();

    expect(document.activeElement).toBe(star);
  });

  it("keeps separate review forms independent", () => {
    const Rating = () => {
      const [rating, setRating] = React.useState<number | null>(null);
      return <RatingSelector currentRating={rating} onChangeCurrentRating={setRating} />;
    };
    render(
      <>
        <Rating />
        <Rating />
      </>,
    );
    const groups = screen.getAllByRole("radiogroup");
    const first = within(assertDefined(groups[0]));
    const second = within(assertDefined(groups[1]));

    fireEvent.click(first.getByRole("radio", { name: "4 stars" }));
    fireEvent.click(second.getByRole("radio", { name: "2 stars" }));

    expect(first.getByRole("radio", { name: "4 stars", checked: true })).toBeTruthy();
    expect(second.getByRole("radio", { name: "2 stars", checked: true })).toBeTruthy();
  });

  it("focuses the written review on repeated pointer selection without saving the rating twice", () => {
    const onChange = vi.fn();
    const onPointerSelect = vi.fn();
    const Rating = () => {
      const [rating, setRating] = React.useState<number | null>(null);
      return (
        <RatingSelector
          currentRating={rating}
          onChangeCurrentRating={(value) => {
            setRating(value);
            onChange(value);
          }}
          onPointerSelect={onPointerSelect}
        />
      );
    };
    render(<Rating />);
    const star = screen.getByRole("radio", { name: "3 stars" });

    fireEvent.click(star, { detail: 1 });
    fireEvent.click(star, { detail: 1 });

    expect(onChange).toHaveBeenCalledExactlyOnceWith(3);
    expect(onPointerSelect).toHaveBeenCalledTimes(2);
  });

  it("does not let a disabled review change its rating", () => {
    const onChange = vi.fn();
    render(<RatingSelector currentRating={3} onChangeCurrentRating={onChange} disabled />);

    const star = screen.getByRole<HTMLElement>("radio", { name: "5 stars" });
    star.focus();
    fireEvent.click(star);

    expect(document.activeElement).not.toBe(star);
    expect(onChange).not.toHaveBeenCalled();
    expect(screen.getByRole("radio", { name: "3 stars", checked: true })).toBeTruthy();
  });
});
