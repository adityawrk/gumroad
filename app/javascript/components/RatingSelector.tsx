import { Star } from "@boxicons/react";
import * as React from "react";

import { Label } from "$app/components/ui/Label";
import { Radio } from "$app/components/ui/Radio";

type Props = {
  currentRating: null | number;
  onChangeCurrentRating: (newRating: number) => void;
  onPointerSelect?: () => void;
  disabled?: boolean;
};
export const RatingSelector = ({ currentRating, onChangeCurrentRating, onPointerSelect, disabled = false }: Props) => {
  const groupName = React.useId();
  const [hoveredRating, setHoveredRating] = React.useState<null | number>(null);

  return (
    <div className="flex shrink-0 items-center" role="radiogroup" aria-label="Your rating:">
      {[1, 2, 3, 4, 5].map((rating) => {
        const filled =
          (currentRating != null && currentRating >= rating) || (hoveredRating != null && hoveredRating >= rating);
        return (
          <Label
            key={rating}
            className="relative rounded-sm has-[:focus-visible]:outline-2 has-[:focus-visible]:outline-offset-2"
            onMouseOver={() => {
              if (!disabled) setHoveredRating(rating);
            }}
            onMouseOut={() => setHoveredRating(null)}
          >
            <Radio
              name={groupName}
              aria-label={`${rating} ${rating === 1 ? "star" : "stars"}`}
              checked={currentRating === rating}
              disabled={disabled}
              className="sr-only!"
              wrapperClassName="absolute inset-0 [&>span]:hidden!"
              onChange={() => onChangeCurrentRating(rating)}
              onClick={(event) => {
                if (event.detail > 0) onPointerSelect?.();
              }}
            />
            <Star {...(filled ? { pack: "filled" } : {})} className="size-5" />
          </Label>
        );
      })}
    </div>
  );
};
